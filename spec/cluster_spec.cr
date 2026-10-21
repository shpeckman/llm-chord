# spec/cluster_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private GREETER = C.remote("t.greeter", version: 1, input: T.object({session: T.string}),
  host: C.host_family("session:", "session"),
  variants: {main: C.variant(state: {count: T.object({n: T.number})}, methods: {greet: C.method(T.string, T.string)})})

private GREETER_V2 = C.remote("t.greeter", version: 2, input: T.object({session: T.string}),
  host: C.host_family("session:", "session"),
  variants: {main: C.variant(methods: {hello: C.method(T.string, T.string)})})

private SERVER_GREETER = C.remote("t.server-greeter", version: 1, input: T.object, host: C.host_named("server"),
  variants: {main: C.variant(state: {count: T.object({n: T.number})}, methods: {greet: C.method(T.string, T.string)})})

private PING = C.remote("t.cluster-ping", version: 1, input: T.object, host: C.host_named("server"),
  variants: {main: C.variant(methods: {ping: C.method(nil, T.string)})})

private def greeter_implementation(scope : ObjectScope, greeting : String, fail : Bool, state_version : Int32) : Implementation
  raise "worker factory fails" if fail
  count = scope.state("count", T.object({n: T.number}), {n: 0}, version: state_version)
  Implementation.new("main").state("count", count).method("greet") do |name, ctx|
    count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + 1 }
    "#{greeting} #{name.not_nil!.as_s}"
  end
end

private def greeter_facet(greeting : String, fail : Bool = false, state_version : Int32 = 1) : Facet
  C.define_facet("greeter") do |api|
    type = api.name == "server" ? SERVER_GREETER : GREETER
    api.serve(type) { |_input, _principal, scope| greeter_implementation(scope, greeting, fail, state_version) }
  end
end

private def empty_facet(name : String) : Facet
  C.define_facet(name) { }
end

private def module_loader(modules : Hash(String, Facet)) : FacetLoader
  ->(names : Array(String)) { names.map { |name| modules[name] } }
end

private def greet(ref : Ref, name : String, ctx : Ctx? = nil) : String
  ref.call("greet", name, ctx).not_nil!.as_s
end

private def chord_error(code : ErrorCode, &) : ChordError
  error = expect_raises(ChordError) { yield }
  error.code.should eq code
  error
end

private class DroppingLink < LLM::Chord::Link
  def initialize(@inner : LLM::Chord::Link, @drop : Proc(Frame, Bool)); end

  def closed? : Bool
    @inner.closed?
  end

  def send(frame : Frame) : Int32?
    @drop.call(frame) ? nil : @inner.send(frame)
  end

  def receive(&handler : Frame -> Nil) : Nil
    @inner.receive(&handler)
  end

  def on_close(&handler : String -> Nil) : Nil
    @inner.on_close(&handler)
  end

  def close(reason : String = "closed") : Nil
    @inner.close(reason)
  end
end

private record Cluster, server : Host, worker : Host, modules : Hash(String, Facet), down : LLM::Chord::Link

private def setup_cluster : Cluster
  modules = {"greeter" => greeter_facet("v1")}
  server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
  down, up = C.memory_link_pair
  server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:S1")
  worker = C.create_host(self: {kind: "host"}, name: "session:S1", on_error: quiet_on_error,
    upstream: C.upstream(up, principal: {kind: "server"}), loader: module_loader(modules))
  worker.install(modules["greeter"])
  Cluster.new(server, worker, modules, down)
end

private def worker_host(name : String, up : LLM::Chord::Link, loader : FacetLoader? = nil) : Host
  C.create_host(self: {kind: "host"}, name: name, on_error: quiet_on_error,
    upstream: C.upstream(up, principal: {kind: "server"}), loader: loader)
end

private def remote_greeter : Hash(String, Array(String))
  {"session:" => ["greeter"]}
end

describe "cross-host reload" do
  it "prepares every host, commits the server first, then the workers; code versions stay in step" do
    cluster = setup_cluster
    server = cluster.server
    worker = cluster.worker
    tick
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a").should eq "v1 a"
    go = Future(Nil).new
    pinned = Future(String).run do
      server.root do |ctx|
        greet(greeter, "p", ctx)
        go.wait
        greet(greeter, "p", ctx)
      end
    end
    tick
    shapes = [] of String
    greeter.on_shape { |shape| shapes << shape.contract }
    cluster.modules["greeter"] = greeter_facet("v2")
    report = server.reload(remote: remote_greeter)
    greet(greeter, "b").should eq "v2 b"
    server.code_version.should eq report.code_version
    worker.code_version.should eq report.code_version
    go.resolve(nil)
    pinned.wait.should eq "v1 p"
    shapes.size.should eq 1
    eventually { worker.previous_code_version.nil? }
    server.previous_code_version.should be_nil
  end

  it "a failing vote aborts every host; the error keeps its code and names the host" do
    cluster = setup_cluster
    server = cluster.server
    worker = cluster.worker
    tick
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a")
    before = {server.code_version, worker.code_version}
    cluster.modules["greeter"] = greeter_facet("v2", fail: true)
    error = chord_error(ErrorCode::Unavailable) { server.reload(remote: remote_greeter) }
    (error.message || "").should match(/session:S1: .*worker factory fails/)
    {server.code_version, worker.code_version}.should eq before
    greet(greeter, "x").should eq "v1 x"
  end

  it "a worker gate blocked past its deadline aborts the whole reload" do
    cluster = setup_cluster
    server = cluster.server
    worker = cluster.worker
    tick
    greeter = server.hold(GREETER, {session: "S1"})
    go = Future(Nil).new
    blocker = Future(Nil).run { server.root { |ctx| greet(greeter, "g", ctx); go.wait } }
    tick
    before = {server.code_version, worker.code_version}
    cluster.modules["greeter"] = greeter_facet("v2", state_version: 2)
    error = chord_error(ErrorCode::Aborted) { server.reload(remote: remote_greeter, gate_deadline: 30.milliseconds) }
    error.reason.should eq "gate_deadline"
    (error.message || "").should match(/session:S1: .*blocking roots: server#\w+:\d+/)
    {server.code_version, worker.code_version}.should eq before
    go.resolve(nil)
    blocker.wait
    greet(greeter, "x").should eq "v1 x"
  end

  it "removes facets from server and workers, reconciles removal tombstones, and clears them on re-add" do
    cluster = setup_cluster
    server = cluster.server
    modules = cluster.modules
    server.install(greeter_facet("v1"))
    tick
    own = server.hold(SERVER_GREETER)
    child = server.hold(GREETER, {session: "S1"})
    greet(own, "a").should eq "v1 a"
    greet(child, "a").should eq "v1 a"
    server.reload(remove: ["greeter"], remote_remove: {"session:" => ["greeter"]})
    eventually { child.status.gone? }
    own.status.should eq RefStatus::Gone
    cold = C.create_host(self: {kind: "host"}, name: "session:cold", on_error: quiet_on_error,
      loader: ->(_names : Array(String)) { raise "Removed modules must not be imported"; [] of Facet })
    cold.install(greeter_facet("v1"))
    old = cold.hold(GREETER, {session: "cold"})
    old.ready.wait
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "cold"}, kind: :host, name: "session:cold")
    cold.connect(up, principal: {kind: "server"})
    eventually { old.status.gone? }
    cold.code_version.should eq server.code_version
    cold.close
    tick
    modules["greeter"] = greeter_facet("v2")
    server.reload([greeter_facet("v2")], remote: remote_greeter)
    greet(server.hold(GREETER, {session: "S1"}), "b").should eq "v2 b"
    fresh = C.create_host(self: {kind: "host"}, name: "session:fresh", on_error: quiet_on_error, loader: module_loader(modules))
    fresh.install(greeter_facet("v1"))
    fresh_down, fresh_up = C.memory_link_pair
    server.accept(fresh_down, principal: {worker: "fresh"}, kind: :host, name: "session:fresh")
    fresh.connect(fresh_up, principal: {kind: "server"})
    greet(server.hold(GREETER, {session: "fresh"}), "c").should eq "v2 c"
    fresh.close
    cluster.worker.close
    server.close
  end

  it "only the server coordinates reloads" do
    cluster = setup_cluster
    tick
    chord_error(ErrorCode::Unavailable) { cluster.worker.reload }.reason.should eq "not_coordinator"
  end

  it "browsers are not participants: they see shape and reset pushes, or upgrade_required" do
    cluster = setup_cluster
    server = cluster.server
    worker_link = cluster.down
    server.route("session:", Route.new(
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(_host : String) { worker_link },
      principal: ->(name : String) { {host: name} }))
    down, up = C.memory_link_pair
    server.accept(down, principal: {guest: "g"})
    browser = C.create_host(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    viewer = browser.hold(GREETER, {session: "S1"})
    greet(viewer, "a").should eq "v1 a"
    shapes = [] of String
    viewer.on_shape { |shape| shapes << shape.contract }
    cluster.modules["greeter"] = greeter_facet("v2")
    server.reload(remote: remote_greeter)
    eventually { shapes.size == 1 }
    greet(viewer, "b").should eq "v2 b"
    cluster.modules["greeter"] = C.define_facet("greeter") do |api|
      api.serve(GREETER_V2) { Implementation.new("main").method("hello") { |name| "hi #{name.not_nil!.as_s}" } }
    end
    server.reload(remote: remote_greeter)
    eventually { viewer.status.gone? }
    C.chord_error?(viewer.error.not_nil!, ErrorCode::UpgradeRequired).should be_true
  end

  it "an abort while a worker is still preparing: a late open closes itself and the worker can reload again" do
    cluster = setup_cluster
    server = cluster.server
    worker = cluster.worker
    tick
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a")
    log = [] of String
    go = Future(Nil).new
    cluster.modules["greeter"] = C.define_facet("greeter") do |api|
      api.serve(GREETER) do |_input, _principal, scope|
        scope.resource("late", version: 1, close: ->(_value : Bool) { log << "closed" }) { go.wait; log << "opened"; true }
        count = scope.state("count", T.object({n: T.number}), {n: 0})
        Implementation.new("main").state("count", count).method("greet") { |name| "slow #{name.not_nil!.as_s}" }
      end
    end
    code_version = worker.code_version
    chord_error(ErrorCode::Aborted) { server.reload(remote: remote_greeter, vote_deadline: 50.milliseconds) }
    go.resolve(nil)
    eventually { log.includes?("closed") }
    log.should eq ["opened", "closed"]
    worker.code_version.should eq code_version
    cluster.modules["greeter"] = greeter_facet("v3")
    server.reload(remote: remote_greeter)
    greet(greeter, "b").should eq "v3 b"
  end

  it "a child that says hello while a reload runs is reconciled after it, never left in step with the old code" do
    modules = {"greeter" => greeter_facet("v1")}
    loading = Future(Nil).new
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error,
      loader: ->(names : Array(String)) { loading.wait; names.map { |name| empty_facet(name) } })
    reloading = Future(ReloadReport).run { server.reload(["server-plugin"], remote: remote_greeter) }
    tick
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up, module_loader(modules))
    worker.install(modules["greeter"])
    tick
    modules["greeter"] = greeter_facet("v2")
    loading.resolve(nil)
    report = reloading.wait
    (report.children.try(&.keys) || [] of String).should be_empty
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a").should eq "v2 a"
    worker.code_version.should eq server.code_version
    worker.close
    server.close
  end

  it "a child keeps the previous code version until its parent retired it" do
    cluster = setup_cluster
    server = cluster.server
    worker = cluster.worker
    tick
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a").should eq "v1 a"
    first = server.code_version
    go = Future(Nil).new
    pinned = Future(String).run { server.root { |ctx| go.wait; greet(greeter, "p", ctx) } }
    tick
    cluster.modules["greeter"] = greeter_facet("v2")
    server.reload(remote: remote_greeter)
    eventually { worker.previous_code_version == first }
    second = Future(ReloadReport).run { server.reload(remote: {"session:" => [] of String}, retire_deadline: 2.seconds) }
    tick
    tick
    worker.previous_code_version.should eq first
    go.resolve(nil)
    pinned.wait.should eq "v1 p"
    second.wait
    server.previous_code_version.should be_nil
  end

  it "a child reconciled after its parent retired old code versions may retire its own previous one at once" do
    modules = {"greeter" => greeter_facet("v1")}
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.install(empty_facet("server-plugin"))
    server.reload([empty_facet("server-plugin")])
    server.reload([empty_facet("server-plugin")])
    server.previous_code_version.should be_nil
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up, module_loader(modules))
    worker.install(modules["greeter"])
    eventually { worker.code_version == server.code_version }
    eventually { worker.previous_code_version.nil? }
    started = Time.instant
    server.reload(remote: remote_greeter, retire_deadline: 10.seconds)
    (Time.instant - started).should be < 2.seconds
    worker.close
    server.close
  end

  it "a reconciliation running when a reload starts syncs the child only after it, to the committed code version" do
    modules = {"greeter" => greeter_facet("v1")}
    server_loading = Future(Nil).new
    block_server = false
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error,
      loader: ->(names : Array(String)) { server_loading.wait if block_server; names.map { |name| empty_facet(name) } })
    server.install(empty_facet("server-plugin"))
    server.reload(["server-plugin"], remote: remote_greeter)
    worker_loading = Future(Nil).new
    block_worker = true
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up, ->(names : Array(String)) {
      worker_loading.wait if block_worker
      names.map { |name| modules[name] }
    })
    worker.install(modules["greeter"])
    tick
    block_server = true
    modules["greeter"] = greeter_facet("v2")
    reloading = Future(ReloadReport).run { server.reload(["server-plugin"], remote: remote_greeter) }
    tick
    block_worker = false
    worker_loading.resolve(nil)
    eventually { worker.code_version == 2 }
    server_loading.resolve(nil)
    report = reloading.wait
    (report.children.try(&.keys) || [] of String).should be_empty
    report.code_version.should eq 3
    greeter = server.hold(GREETER, {session: "S1"})
    greet(greeter, "a").should eq "v2 a"
    worker.code_version.should eq server.code_version
    worker.close
    server.close
  end

  it "a child behind whose hello waits for a running reload is fenced at once: its calls up are admitted" do
    ping_facet = C.define_facet("ping") { |api| api.serve(PING) { Implementation.new("main").method("ping") { "pong" } } }
    loading = Future(Nil).new
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error,
      loader: ->(names : Array(String)) { loading.wait; names.map { |name| empty_facet(name) } })
    server.install(ping_facet)
    server.reload([ping_facet])
    server.previous_code_version.should be_nil
    reloading = Future(ReloadReport).run { server.reload(["server-plugin"], remote: {"session:" => [] of String}) }
    tick
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up)
    worker.root { |ctx| ctx.get(PING).call("ping", ctx) }.should eq JSON::Any.new("pong")
    loading.resolve(nil)
    reloading.wait
    eventually { worker.code_version == server.code_version }
    worker.close
    server.close
  end

  it "a reconnecting child behind its parent, still retaining its previous code version, reconciles without waiting out the retire deadline" do
    modules = {"greeter" => greeter_facet("v1")}
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, up = C.memory_link_pair
    server.accept(DroppingLink.new(down, ->(frame : Frame) { frame.t == "retire" }),
      principal: {worker: "w"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up, module_loader(modules))
    worker.install(modules["greeter"])
    tick
    modules["greeter"] = greeter_facet("v2")
    server.reload(remote: remote_greeter)
    tick
    worker.previous_code_version.should eq 1
    up.close("gone")
    tick
    modules["greeter"] = greeter_facet("v3")
    server.reload([empty_facet("server-plugin")])
    down2, up2 = C.memory_link_pair
    server.accept(down2, principal: {worker: "w"}, kind: :host, name: "session:S1")
    started = Time.instant
    worker.connect(up2, principal: {kind: "server"})
    eventually(4.seconds) { worker.code_version == server.code_version }
    (Time.instant - started).should be < 2.seconds
    worker.close
    server.close
  end

  it "forced retirement cancels a browser call relayed to a worker before the server closes the old code's resources" do
    log = [] of String
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, up = C.memory_link_pair
    worker = worker_host("session:S1", up)
    never = Future(Nil).new
    slow = C.remote("t.cluster-slow", version: 1, input: T.object, host: C.host_named("session:S1"),
      variants: {main: C.variant(methods: {wait: C.method})})
    worker.serve(slow) do
      Implementation.new("main").method("wait") do |_args, ctx|
        ctx.signal.on_abort { log << "worker aborted" }
        never.wait
      end
    end
    watched = DroppingLink.new(down, ->(frame : Frame) { log << "cancel sent" if frame.t == "cancel"; false })
    server.route("session:", Route.new(
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(_host : String) { watched },
      principal: ->(name : String) { {host: name} }))
    store = C.local("t.cluster-store", version: 1, input: T.object)
    store_facet = ->(version : Int32) do
      C.define_facet("store") do |api|
        api.serve(store, lifetime: :host) do |_input, _principal, scope|
          scope.resource("conn", version: version, close: ->(_value : Bool) { log << "server closes #{version}" }) { true }
          Implementation.new
        end
      end
    end
    server.install(store_facet.call(1))
    browser_down, browser_up = C.memory_link_pair
    server.accept(browser_down, principal: {guest: "g"})
    browser = C.create_host(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(browser_up, principal: {kind: "server"}))
    call = Future(JSON::Any?).run { browser.hold(slow).call("wait") }
    sleep 20.milliseconds
    server.reload([store_facet.call(2)])
    server.reload([store_facet.call(3)], retire_deadline: 20.milliseconds)
    call.wait(Array(AbortSignal).new, 2.seconds).settled?.should be_true
    call.rejected?.should be_true
    eventually { log.includes?("worker aborted") }
    log.select { |entry| entry == "cancel sent" || entry == "server closes 1" }.should eq ["cancel sent", "server closes 1"]
    never.resolve(nil)
    browser.close
    worker.close
    server.close
  end

  it "roots of a child that connected behind the server are admitted in the server's code version" do
    echo = C.remote("t.echo", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(methods: {codeVersion: C.method(nil, T.number)})})
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    echo_facet = C.define_facet("echo") { |api| api.serve(echo) { Implementation.new("main").method("codeVersion") { |_args, ctx| ctx.code_version } } }
    server.install(echo_facet)
    server.reload([echo_facet])
    server.code_version.should eq 2
    server.previous_code_version.should be_nil
    worker = C.create_host(self: {kind: "host"}, name: "session:S1", on_error: quiet_on_error,
      loader: ->(_names : Array(String)) { [] of Facet })
    go = Future(Nil).new
    call = Future(JSON::Any?).run { worker.root { |ctx| go.wait; ctx.get(echo).call("codeVersion", ctx) } }
    tick
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "S1"}, kind: :host, name: "session:S1")
    worker.connect(up, principal: {kind: "server"})
    go.resolve(nil)
    call.wait.should eq JSON::Any.new(2_i64)
    eventually { worker.code_version == 2 }
    chord_error(ErrorCode::Superseded) { server.root(code_version: 1) { 0 } }
    worker.close
    server.close
  end

  it "a cluster reload reports what each child prepared" do
    greeter_type = C.remote("t.greeter-s1", version: 1, input: T.object, host: C.host_named("session:S1"),
      variants: {main: C.variant(methods: {greet: C.method(T.string, T.string)})})
    greeter = ->(text : String) do
      C.define_facet("greeter") { |api| api.serve(greeter_type) { Implementation.new("main").method("greet") { |name| "#{text} #{name.not_nil!.as_s}" } } }
    end
    modules = {"greeter" => greeter.call("v1")}
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "S1"}, kind: :host, name: "session:S1")
    worker = worker_host("session:S1", up, module_loader(modules))
    worker.install(greeter.call("v1"))
    tick
    ref = server.hold(greeter_type)
    greet(ref, "a").should eq "v1 a"
    modules["greeter"] = greeter.call("v2")
    report = server.reload(remote: remote_greeter)
    report.changed.should be_empty
    child = report.children.not_nil!["session:S1"]
    child.changed.should eq ["t.greeter-s1"]
    child.prepared.size.should eq 1
    child.code_version.should eq report.code_version
    worker.close
    server.close
  end
end
