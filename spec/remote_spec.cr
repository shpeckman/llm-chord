# spec/remote_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private SOURCE = C.remote("t.e8-source", version: 1, input: T.object, host: C.host_named("w"),
  variants: {main: C.variant(state: {v: T.string}, methods: {set: C.method(T.string)})})

private FORWARD = C.remote("t.e8-forward", version: 1, input: T.object({how: T.string}), host: C.host_named("server"),
  variants: {main: C.variant(state: {v: T.string, size: T.number})})

private def serve_source(host : Host) : Nil
  host.serve(SOURCE) do |_input, _principal, scope|
    v = scope.state("v", T.string, "from the worker")
    Implementation.new("main").state("v", v).method("set") { |text, ctx| v.replace(ctx, text.not_nil!) }
  end
end

private record HydrationCluster, server : Host, worker : Host, down : MemoryLink

private def cluster(delay : Time::Span? = nil, ready_timeout : Time::Span? = 60.seconds) : HydrationCluster
  server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error, ready_timeout: ready_timeout)
  down, up = C.memory_link_pair
  worker = Host.new(self: {kind: "host"}, name: "w", on_error: quiet_on_error, ready_timeout: ready_timeout,
    upstream: C.upstream(up, principal: {kind: "server"}))
  admit = -> { server.accept(down, principal: {kind: "worker"}, kind: :host, name: "w") }
  if span = delay
    spawn { sleep span; admit.call }
  else
    admit.call
  end
  HydrationCluster.new(server, worker, down)
end

private def browser_of(server : Host) : Host
  down, up = C.memory_link_pair
  server.accept(down, principal: {user: "u"})
  Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
    upstream: C.upstream(up, principal: {kind: "server"}))
end

describe "hydration across hosts" do
  it "an object that forwards and derives from a remote member goes live with its value" do
    c = cluster
    serve_source(c.worker)
    c.server.serve(FORWARD) do |_input, _principal, scope|
      source = scope.get(SOURCE)
      Implementation.new("main")
        .state("v", source.state("v"))
        .state("size", scope.derive([source.state("v")]) { |(text)| text.as_s.size })
    end
    forward = c.server.get(FORWARD, {how: "direct"})
    forward.state("v").value.should eq JSON::Any.new("from the worker")
    forward.state("size").value.should eq JSON::Any.new(15_i64)
    browser = browser_of(c.server)
    remote = browser.get(FORWARD, {how: "direct"})
    remote.state("v").value.should eq JSON::Any.new("from the worker")
    c.server.hold(SOURCE).call("set", "changed")
    eventually { remote.state("v").value == JSON::Any.new("changed") && remote.state("size").value == JSON::Any.new(7_i64) }
    browser.close
    c.server.close
    c.worker.close
  end

  it "a host object of a child holding the parent's object goes live once the parent admits the child" do
    settings = C.remote("t.e8-settings", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(state: {theme: T.string})})
    boot_contract = C.local("t.e8-boot", version: 1, input: T.object, members: {theme: T.string})
    c = cluster(delay: 20.milliseconds)
    c.server.serve(settings) { |_input, _principal, scope| Implementation.new("main").state("theme", scope.state("theme", T.string, "dark")) }
    boot = C.define_facet("boot") do |api|
      api.serve(boot_contract, lifetime: :host) do |_input, _principal, scope|
        Implementation.new.state("theme", scope.get(settings).state("theme"))
      end
    end
    c.worker.install(boot, await_host_objects: false)
    c.worker.ready
    held = c.worker.hold(boot_contract)
    held.ready.wait
    held.state("theme").value.should eq JSON::Any.new("dark")
    c.server.close
    c.worker.close
  end

  it "a reference cycle across hosts fails at ready_timeout with a cycle hint" do
    a = C.remote("t.e8-cycle-a", version: 1, input: T.object, host: C.host_named("server"), variants: {main: C.variant})
    b = C.remote("t.e8-cycle-b", version: 1, input: T.object, host: C.host_named("w"), variants: {main: C.variant})
    c = cluster(ready_timeout: 50.milliseconds)
    c.server.serve(a) { |_input, _principal, scope| scope.get(b); Implementation.new("main") }
    c.worker.serve(b) { |_input, _principal, scope| scope.get(a); Implementation.new("main") }
    error = expect_raises(ChordError) { c.server.hold(a).ready.wait }
    error.code.should eq ErrorCode::Unavailable
    error.reason.should eq "ready_timeout"
    error.message.not_nil!.should contain "cycle"
    sleep 10.milliseconds
    c.server.close
    c.worker.close
  end
end

describe "re-hold after a link loss" do
  doc = C.remote("t.e8-doc", version: 1, input: T.object, host: C.host_named("server"), variants: {
    b: C.variant(state: {x: T.number, y: T.string}, methods: {bump: C.method}),
  })

  it "keeps the last values readable, sends one fresh unit, and a reference joining meanwhile waits for it" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(doc) do |_input, _principal, scope|
      x = scope.state("x", T.number, 1)
      y = scope.state("y", T.string, "why")
      Implementation.new("b").state("x", x).state("y", y).method("bump") { |_args, ctx| x.replace(ctx, x.value.as_i + 1) }
    end
    down, up = C.memory_link_pair
    server.accept(down, principal: {user: "u"})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    ref = browser.hold(doc)
    ref.ready.wait
    ref.call("bump")
    eventually { ref.state("x").value == JSON::Any.new(2_i64) }
    up.close
    eventually { ref.status.loading? }
    ref.state("x").value.should eq JSON::Any.new(2_i64)
    joining = browser.hold(doc)
    joining.status.should eq RefStatus::Loading
    sleep 5.milliseconds
    joining.ready.settled?.should be_false
    down2, up2 = C.memory_link_pair
    server.accept(down2, principal: {user: "u"})
    link = CountingLink.new(up2)
    browser.connect(link, principal: {kind: "server"})
    joining.ready.wait
    ref.status.should eq RefStatus::Live
    hold = link.sent.find! { |frame| frame.t == "hold" }
    hold["again"]?.should eq JSON::Any.new(true)
    link.count(:sent, "hold").should eq 1
    state_frames(link.received).select { |frame| frame.string("as") == "snap" }.map(&.string("m")).sort.should eq ["x", "y"]
    ref.state("x").value.should eq JSON::Any.new(1_i64)
    browser.close
    server.close
  end
end

describe "principals across links" do
  it "a child's parent acts as the principal the child gave connect; relayed callers keep theirs" do
    key = ->(principal : JSON::Any) { principal["kind"].as_s == "guest" ? "guest:#{principal["id"]}" : principal["kind"].as_s }
    echo = C.remote("t.echo", version: 1, input: T.object, host: C.host_named("worker"),
      variants: {main: C.variant(methods: {who: C.method(nil, T.string)})})
    server = Host.new(name: "server", self: {kind: "host"}, principal_key: key, on_error: quiet_on_error)
    down, up = C.memory_link_pair
    server.accept(down, kind: :host, name: "worker", principal: {kind: "host"})
    worker = Host.new(name: "worker", self: {kind: "host"}, principal_key: key, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    worker.serve(echo) { |_input, principal| Implementation.new("main").method("who") { key.call(principal) } }
    browser_down, browser_up = C.memory_link_pair
    server.accept(browser_down, principal: {kind: "guest", id: "g1"})
    browser = Host.new(name: "browser", kind: :client, self: {kind: "host"}, principal_key: key, on_error: quiet_on_error,
      upstream: C.upstream(browser_up, principal: {kind: "server"}))
    server.hold(echo).call("who").should eq JSON::Any.new("server")
    server.route("worker", Route.new(
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(_name : String) { down },
      principal: ->(_name : String) { {kind: "host"} },
    ))
    browser.hold(echo).call("who").should eq JSON::Any.new("guest:g1")
    browser.close
    worker.close
    server.close
  end
end

describe "requests across links" do
  it "a held object's state member can be returned as this object's state member, also across a link" do
    view = T.object({text: T.string})
    conv = C.remote("t.conv", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(state: {view: view}, methods: {set: C.method(T.string)})})
    chat = C.remote("t.chat", version: 1, input: T.object, host: C.host_named("server"),
      variants: {viewer: C.variant(state: {view: view})})
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(conv) do |_input, _principal, scope|
      state = scope.state("view", view, {text: ""})
      Implementation.new("main").state("view", state).method("set") { |text, ctx| state.replace(ctx, {text: text}) }
    end
    server.serve(chat) { |_input, _principal, scope| Implementation.new("viewer").state("view", scope.get(conv).state("view")) }
    local_chat = server.hold(chat)
    values = [] of JSON::Any
    local_chat.state("view").subscribe { |value| values << value }
    local_chat.ready.wait
    server.hold(conv).call("set", "hi")
    eventually { values.last? == j(%({"text":"hi"})) }
    browser = browser_of(server)
    remote_chat = browser.hold(chat)
    remote_chat.ready.wait
    server.hold(conv).call("set", "there")
    eventually { remote_chat.state("view").value == j(%({"text":"there"})) }
  end

  it "a held remote reference keeps its state without listeners; a later subscriber sees the current value" do
    counter = C.remote("t.count8", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(state: {n: T.number}, methods: {set: C.method(T.number)})})
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(counter) do |_input, _principal, scope|
      n = scope.state("n", T.number, 0)
      Implementation.new("main").state("n", n).method("set") { |value, ctx| n.replace(ctx, value.not_nil!) }
    end
    browser = browser_of(server)
    ref = browser.hold(counter)
    ref.ready.wait
    ref.state("n").value.should eq JSON::Any.new(0_i64)
    stop = ref.state("n").subscribe { }
    ref.call("set", 1)
    eventually { ref.state("n").value == JSON::Any.new(1_i64) }
    stop.call
    ref.call("set", 2)
    eventually { ref.state("n").value == JSON::Any.new(2_i64) }
    seen = [] of JSON::Any
    again = ref.state("n").subscribe { |value| seen << value }
    seen.should eq [JSON::Any.new(2_i64)]
    again.call
  end

  it "references report status changes: live, loading while a link reconnects, gone, released" do
    thing = C.remote("t.thing9", version: 1, input: T.object, host: C.host_named("server"), variants: {main: C.variant})
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(thing) { Implementation.new("main") }
    local_thing = server.hold(thing, nil, principal: {user: "u"})
    local_status = [] of String
    local_thing.on_status { |status, error| local_status << (status.gone? ? "gone:#{error.as(ChordError).code.label}" : status.label) }
    local_thing.ready.wait
    tick
    server.invalidate_principal({user: "u"})
    tick
    local_status.should eq ["live", "gone:gone"]

    down, up = C.memory_link_pair
    server.accept(down, principal: {guest: "g"})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    remote_thing = browser.hold(thing)
    remote_status = [] of String
    remote_thing.on_status { |status| remote_status << status.label }
    remote_thing.ready.wait
    up.close
    eventually { remote_status.size == 2 }
    down2, up2 = C.memory_link_pair
    server.accept(down2, principal: {guest: "g"})
    browser.connect(up2, principal: {kind: "server"})
    eventually { remote_status.size == 3 }
    remote_thing.release
    tick
    remote_status.should eq ["live", "loading", "live", "released"]
  end

  it "host close disposes holders before what they hold, and before closing links" do
    log = [] of String
    note_contract = C.remote("t.remote10", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(methods: {note: C.method(T.string)})})
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(note_contract) { Implementation.new("main").method("note") { |text| log << "server: #{text.not_nil!.as_s}"; nil } }
    proc_contract = C.local("t.proc", version: 1, input: T.object, members: {tracker: C.opaque("t.tracker@1")})
    chat = C.local("t.chat10", version: 1, input: T.object)
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "w")
    worker = Host.new(self: {kind: "host"}, name: "w", on_error: ->(error : Exception) { log << "error: #{error.message}"; nil },
      upstream: C.upstream(up, principal: {kind: "server"}))
    worker.serve(proc_contract, lifetime: :host) do |_input, _principal, scope|
      tracker = scope.resource("tracker", version: 1, close: ->(_set : Set(String)) { log << "proc closed"; nil }) { Set(String).new }
      Implementation.new.expose("tracker", scope.expose(tracker))
    end
    sleep 5.milliseconds
    worker.serve(chat) do |_input, _principal, scope|
      held = scope.get(proc_contract)
      upstream = scope.get(note_contract)
      scope.resource("session", version: 1, close: ->(_value : Bool) do
        tracker = held.opaque("tracker", Set(String))
        tracker.try &.delete("chat")
        log << "chat closed, proc #{held.status.label}, tracker #{tracker ? "ok" : "gone"}"
        upstream.call("note", "bye")
        nil
      end) { held.opaque("tracker", Set(String)).try &.add("chat"); true }
      Implementation.new
    end
    worker.hold(chat).ready.wait
    worker.close
    log.should eq ["chat closed, proc live, tracker ok", "server: bye", "proc closed"]
  end
end

describe "readiness across links" do
  %w[install load].each do |operation|
    it "#{operation} can defer eager readiness until the parent admits the worker" do
      server = Host.new(self: {kind: "host"}, name: "server", on_error: ->(error : Exception) { raise error })
      parent, upstream = C.memory_link_pair
      worker = Host.new(self: {kind: "host"}, name: "worker", on_error: ->(error : Exception) { raise error },
        upstream: C.upstream(upstream, principal: {kind: "server"}))
      status_contract = C.remote("ready.status", version: 1, input: T.object, host: C.host_named("server"),
        variants: {default: C.variant})
      lazy = C.local("ready.lazy", version: 1, input: T.object)
      eager = C.local("ready.eager", version: 1, input: T.object)
      server.serve(status_contract) { Implementation.new("default") }
      bootstrap = false
      reported = false
      facet = C.define_facet("worker") do |api|
        api.serve(lazy, lifetime: :host) do
          bootstrap = true
          Implementation.new
        end
        api.serve(eager, lifetime: :host) do |_input, _principal, scope|
          status = scope.get(status_contract)
          scope.resource("r", version: 1, deps: [status]) { reported = true }
          Implementation.new
        end
      end
      operation == "install" ? worker.install(facet, await_host_objects: false) : worker.load([facet], await_host_objects: false)
      worker.hold(lazy).ready.wait
      bootstrap.should be_true
      ready = Future(Nil).run { worker.ready }
      tick
      ready.settled?.should be_false
      reported.should be_false
      server.accept(parent, kind: :host, name: "worker", principal: {host: "worker"})
      ready.wait
      reported.should be_true
    ensure
      worker.try &.close
      server.try &.close
    end
  end
end
