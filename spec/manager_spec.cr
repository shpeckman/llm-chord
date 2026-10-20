# spec/manager_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private ECHO = C.remote("t.echo", version: 1, input: T.object, host: C.host_named("w1"), variants: {
  main: C.variant(methods: {echo: C.method(T.string, T.string), pid: C.method(nil, T.number)}),
})

private WORKER = begin
  path = File.join(Dir.tempdir, "llm-chord-worker-#{Process.pid}")
  status = Process.run("crystal", ["build", "spec/fixtures/worker.cr", "-o", path], output: STDOUT, error: STDERR)
  raise "worker fixture failed to build" unless status.success?
  Spec.after_suite { File.delete?(path) }
  path
end

private def driver(env : Hash(String, String) = {} of String => String, lock : String? = nil) : ForkDriver
  C.fork_driver(WORKER, env: {"HOST_NAME" => "w1"}.merge(env), init: {greeting: "hi"}, lock: lock)
end

private def scratch(name : String) : String
  File.join(Dir.tempdir, "chord2-#{Process.pid}-#{name}")
end

private def alive?(pid : Int64) : Bool
  Process.exists?(pid)
end

private class FakeInstance < Instance
  getter pid : Int64 = 0_i64
  getter link : LLM::Chord::Link = C.ipc_link(IpcChannel.new(IO::Memory.new))
  getter exited : Future(Exit) = Future(Exit).new
  getter listeners = [] of Proc(ControlMessage, Nil)

  def send(message : ControlMessage) : Nil
  end

  def kill_tree : Nil
  end

  def on_control(&listener : ControlMessage -> Nil) : Nil
    @listeners << listener
  end

  def emit(message : ControlMessage) : Nil
    @listeners.each(&.call(message))
  end
end

private class FakeDriver < Driver
  getter spawned = [] of FakeInstance

  def spawn : Instance
    instance = FakeInstance.new
    @spawned << instance
    instance
  end
end

private class WatchedDriver < Driver
  getter pids = [] of Int64

  def initialize(@base : Driver); end

  def spawn : Instance
    @pids.each { |pid| raise "pid #{pid} still alive" if Process.exists?(pid) && !zombie?(pid) }
    instance = @base.spawn
    @pids << instance.pid
    instance
  end

  private def zombie?(pid : Int64) : Bool
    File.read("/proc/#{pid}/stat").split(' ')[2] == "Z"
  rescue File::Error
    true
  end
end

describe "process_lock" do
  it "admits one holder and releases on demand" do
    name = "chord2-test-#{Process.pid}-plain"
    release = C.process_lock(name)
    error = expect_raises(ChordError) { C.process_lock(name) }
    error.reason.should eq "locked"
    release.call
    C.process_lock(name).call
  end
end

describe "host manager (real child processes)" do
  it "a child without a lock does not inherit the parent's lock" do
    name = "chord2-test-#{Process.pid}-inherited"
    release = C.process_lock(name)
    previous = ENV[LOCK_ENV]?
    ENV[LOCK_ENV] = name
    manager = C.create_host_manager(driver)
    begin
      manager.start
      manager.status.should eq HostManager::Status::Running
    ensure
      previous ? (ENV[LOCK_ENV] = previous) : ENV.delete(LOCK_ENV)
      manager.stop
      release.call
    end
  end

  it "starts a child host, links it, stops it gracefully" do
    manager = C.create_host_manager(driver)
    instance = manager.start
    manager.status.should eq HostManager::Status::Running
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.accept(instance.link, principal: {worker: "w1"}, kind: :host, name: "w1")
    echo = server.hold(ECHO)
    echo.call("echo", "x").should eq JSON::Any.new("hi x from #{instance.pid}")
    manager.start.should be(instance)
    manager.stop
    manager.status.should eq HostManager::Status::Stopped
    instance.exited.wait.should eq Exit.new(0, nil)
    server.close
  end

  it "a child-owned kernel lock admits one live process; replace waits for the exit before the next start" do
    lock = "chord2-test-#{Process.pid}-lock"
    watched = WatchedDriver.new(driver(lock: lock))
    first = C.create_host_manager(watched)
    second = C.create_host_manager(driver(lock: lock))
    a = first.start
    error = expect_raises(ChordError) { second.start }
    error.code.should eq ErrorCode::Unavailable
    error.reason.should eq "locked"
    b = first.replace
    a.pid.should_not eq b.pid
    first.stop
    second.start
    second.stop
  end

  it "a graceful exit still takes the child's descendants with it" do
    file = scratch("grandchild-graceful")
    File.delete?(file)
    manager = C.create_host_manager(driver({"GRANDCHILD_FILE" => file}))
    manager.start
    grandchild = File.read(file).to_i64
    alive?(grandchild).should be_true
    manager.stop
    eventually { !alive?(grandchild) }
    File.delete?(file)
  end

  it "idle_for counts from the busy -> idle transition" do
    fake = FakeDriver.new
    manager = C.create_host_manager(fake)
    started = Future(Instance).run { manager.start }
    eventually { fake.spawned.size == 1 && !fake.spawned[0].listeners.empty? }
    instance = fake.spawned[0]
    instance.emit(ControlMessage.new("ready"))
    started.wait
    instance.emit(ControlMessage.new("status", active_calls: 1))
    sleep 120.milliseconds
    manager.liveness.idle_for.should eq Time::Span.zero
    instance.emit(ControlMessage.new("status", active_calls: 0))
    (manager.liveness.idle_for < 60.milliseconds).should be_true
  end

  it "kills the process tree when a child ignores shutdown past the grace period" do
    file = scratch("grandchild")
    File.delete?(file)
    manager = C.create_host_manager(driver({"FIXTURE_MODE" => "ignore-shutdown", "GRANDCHILD_FILE" => file}), grace: 300.milliseconds)
    instance = manager.start
    grandchild = File.read(file).to_i64
    alive?(grandchild).should be_true
    manager.stop
    instance.exited.wait.signal.should eq "SIGKILL"
    eventually { !alive?(grandchild) }
    File.delete?(file)
  end

  it "reports a fatal child as a failed start" do
    manager = C.create_host_manager(driver({"FIXTURE_MODE" => "fatal"}))
    expect_raises(ChordError, /fixture refuses to start/) { manager.start }
    manager.status.should eq HostManager::Status::Stopped
  end

  it "stops an idle child when keep_alive says so" do
    exits = [] of Exit
    manager = C.create_host_manager(driver,
      keep_alive: ->(liveness : Liveness) { !liveness.booting && liveness.idle_for < 150.milliseconds },
      check_interval: 50.milliseconds,
      on_exit: ->(exit : Exit) { exits << exit; nil })
    manager.start
    eventually(5.seconds) { manager.status.stopped? }
    eventually { exits.size == 1 }
  end
end

describe "host manager: a Node child" do
  it "speaks Node's IPC framing over NODE_CHANNEL_FD" do
    node = Process.find_executable("node")
    next pending!("node is not installed") unless node
    manager = C.create_host_manager(C.fork_driver(node, ["spec/fixtures/node_child.mjs"], init: {n: 41}))
    instance = manager.start
    frames = [] of Frame
    instance.link.receive { |frame| frames << frame }
    instance.link.send(wire("ping", n: 1))
    eventually { frames.size == 2 }
    frames.map(&.int("n")).sort.should eq [2_i64, 41_i64]
    manager.stop
    instance.exited.wait.should eq Exit.new(0, nil)
  end
end
