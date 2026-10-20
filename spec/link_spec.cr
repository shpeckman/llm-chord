# spec/link_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private COUNTER_VARIANTS = {
  main: C.variant(
    state: {count: T.object({n: T.number})},
    methods: {add: C.method(T.number, T.number), who: C.method(nil, T.unknown)},
  ),
}

private COUNTER = C.remote("t.counter", version: 1, input: T.object({name: T.string}),
  host: C.host_named("server"), variants: COUNTER_VARIANTS)

private SESSION_COUNTER = C.remote("t.session-counter", version: 1,
  input: T.object({session: T.string, name: T.string}),
  host: C.host_family("session:", "session"), variants: COUNTER_VARIANTS)

private BIG = C.remote("t.big", version: 1, input: T.object, host: C.host_named("session:S1"), variants: {
  main: C.variant(state: {notes: T.array(T.string)}, methods: {echo: C.method(T.array(T.string), T.array(T.string))}),
})

private def counter_impl(principal : JSON::Any, scope : ObjectScope, principals : Array(JSON::Any)) : Implementation
  principals << principal
  count = scope.state("count", T.object({n: T.number}), {n: 0})
  Implementation.new("main")
    .state("count", count)
    .method("add") do |delta, ctx|
      count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i }
      count.value["n"]
    end
    .method("who") { principal }
end

private def serve_counter(host : Host, principals : Array(JSON::Any) = [] of JSON::Any) : Nil
  if host.name == "server"
    host.serve(COUNTER) { |_input, principal, scope| counter_impl(principal, scope, principals) }
  else
    host.serve(SESSION_COUNTER) { |_input, principal, scope| counter_impl(principal, scope, principals) }
  end
end

private def large(tag : String) : JSON::Any
  JSON::Any.new((0...40).map { |index| JSON::Any.new("#{tag}#{index}:#{"x" * 4000}") })
end

private def chord_error(code : ErrorCode, &) : ChordError
  error = expect_raises(ChordError) { yield }
  error.code.should eq code
  error
end

private def raw_hello(raw : LLM::Chord::Link, name : String = "raw", protocol : Int32? = PROTOCOL_VERSION) : Nil
  raw.send(wire("hello", protocol: protocol, name: name, kind: "client", codeVersion: 0))
end

private record WorkerPair, server : Host, worker : Host, down : MemoryLink, up : MemoryLink, errors : Array(Exception)

private def server_with_worker(worker_name = "session:S1") : WorkerPair
  errors = [] of Exception
  report = ->(error : Exception) { errors << error; nil }
  server = Host.new(self: {kind: "host"}, name: "server", on_error: report)
  down, up = C.memory_link_pair
  server.accept(down, principal: {worker: worker_name}, kind: :host, name: worker_name)
  worker = Host.new(self: {kind: "host"}, name: worker_name, on_error: report,
    upstream: C.upstream(up, principal: {kind: "server"}))
  WorkerPair.new(server, worker, down, up, errors)
end

private class Browser
  getter host : Host
  property up : MemoryLink

  def initialize(@host : Host, @up : MemoryLink, @server : Host, @principal : JSON::Any); end

  def reconnect : Nil
    down, up = C.memory_link_pair
    @server.accept(down, principal: @principal)
    @up = up
    @host.connect(up, principal: {kind: "server"})
  end
end

private class Cluster
  getter server : Host
  getter workers = {} of String => Host
  getter log = [] of String
  property allow : Proc(JSON::Any, String, Bool) = ->(_principal : JSON::Any, _host : String) { true }

  def initialize(@options : LinkOptions = LinkOptions.new)
    @server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    cluster = self
    @server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(principal : JSON::Any, host : String) { cluster.allow.call(principal, host) },
      resolve: ->(name : String) { cluster.spawn_worker(name) },
    ))
  end

  def browser(principal, restamp : Proc(JSON::Any, JSON::Any?)? = nil) : Browser
    stamped = Json.to_any(principal)
    down, up = C.memory_link_pair
    if restamp
      @server.accept(down, principal: stamped, restamp: restamp, options: @options)
    else
      @server.accept(down, principal: stamped, options: @options)
    end
    host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: Upstream.new(up, j(%({"kind":"server"})), @options))
    Browser.new(host, up, @server, stamped)
  end

  def spawn_worker(name : String) : LLM::Chord::Link
    down, up = C.memory_link_pair
    worker = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
      upstream: Upstream.new(up, j(%({"kind":"server"})), @options))
    log = @log
    worker.serve(SESSION_COUNTER) do |input, principal, scope|
      tag = input["name"].as_s
      scope.resource("probe", version: 1, close: ->(_value : Nil) { log << "close #{tag}"; nil }) { log << "open #{tag}"; nil }
      counter_impl(principal, scope, [] of JSON::Any)
    end
    @workers[name] = worker
    down
  end
end

describe "links: calls and state across hosts" do
  it "a child calls the server; the server stamps the child's principal" do
    pair = server_with_worker
    principals = [] of JSON::Any
    serve_counter(pair.server, principals)
    result = pair.worker.root do |ctx|
      counter = ctx.get(COUNTER, {name: "c"})
      counter.variant.should eq "main"
      [counter.call("add", 2, ctx), counter.call("who", ctx)]
    end
    result.should eq [JSON::Any.new(2_i64), j(%({"worker":"session:S1"}))]
    principals.should eq [j(%({"worker":"session:S1"}))]
  end

  it "state members: snapshot, then delta-encoded ops; values decode to the provider's" do
    pair = server_with_worker
    serve_counter(pair.server)
    counter = pair.worker.hold(COUNTER, {name: "s"})
    events = [] of StateEvent
    values = [] of JSON::Any
    counter.state("count").events { |event| events << event }
    counter.state("count").subscribe { |value| values << value }
    counter.ready.wait
    counter.call("add", 1)
    counter.call("add", 1)
    eventually { values.size == 3 }
    counter.state("count").value.should eq j(%({"n":2}))
    events.map(&.kind).should eq [StateEvent::Kind::Snap, StateEvent::Kind::Ops, StateEvent::Kind::Ops]
    values.should eq [j(%({"n":0})), j(%({"n":1})), j(%({"n":2}))]
  end

  it "the server reaches a connected child by name" do
    pair = server_with_worker("session:w1")
    principals = [] of JSON::Any
    serve_counter(pair.worker, principals)
    tick
    counter = pair.server.hold(SESSION_COUNTER, {session: "w1", name: "x"})
    counter.call("add", 5).should eq JSON::Any.new(5_i64)
    principals.should eq [j(%({"kind":"server"}))]
  end

  it "rejects types the parent does not serve" do
    pair = server_with_worker
    missing = pair.worker.hold(COUNTER, {name: "m"})
    chord_error(ErrorCode::Unavailable) { missing.ready.wait }
  end
end

describe "links: relay, stamping, lifetime" do
  it "relays browser -> server -> worker; the worker sees the browser's stamped principal" do
    c = Cluster.new
    browser = c.browser({guest: "g1"})
    counter = browser.host.hold(SESSION_COUNTER, {session: "S1", name: "a"})
    counter.call("add", 3).should eq JSON::Any.new(3_i64)
    counter.call("who").should eq j(%({"guest":"g1"}))
    values = [] of JSON::Any
    counter.state("count").subscribe { |value| values << value }
    counter.call("add", 1)
    eventually { values.last? == j(%({"n":4})) }
  end

  it "ignores payload principals from clients and from child hosts" do
    c = Cluster.new
    down, raw = C.memory_link_pair
    c.server.accept(down, principal: {guest: "g1"})
    frames = [] of Frame
    raw.receive { |frame| frames << frame }
    raw_hello(raw)
    raw.send(wire("hold", id: 1, at: "session:S1", token: SESSION_COUNTER.description.json,
      input: j(%({"session":"S1","name":"f"})), principal: j(%({"owner":true}))))
    raw.send(wire("call", id: 2, hold: 1, member: "who", args: JSON::Any.new(nil)))
    eventually { frames.any? { |frame| frame.t == "result" } }
    frames.find! { |frame| frame.t == "result" }.payload.should eq j(%({"guest":"g1"}))

    pair = server_with_worker("w9")
    serve_counter(pair.server)
    child_frames = [] of Frame
    pair.up.receive { |frame| child_frames << frame }
    pair.up.send(wire("hold", id: 7, at: "server", token: COUNTER.description.json, input: j(%({"name":"f"})),
      principal: j(%({"owner":true}))))
    pair.up.send(wire("call", id: 8, hold: 7, member: "who", args: JSON::Any.new(nil)))
    eventually { child_frames.any? { |frame| frame.t == "result" } }
    child_frames.find! { |frame| frame.t == "result" }.payload.should eq j(%({"worker":"w9"}))
  end

  it "a route that returns an already closed link does not poison the host name" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    attempt = 0
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        attempt += 1
        down, up = C.memory_link_pair
        worker = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
          upstream: C.upstream(up, principal: {kind: "server"}))
        serve_counter(worker)
        down.close("worker exited") if attempt == 1
        down
      end,
    ))
    first = server.hold(SESSION_COUNTER, {session: "S1", name: "a"})
    expect_raises(ChordError, /closed/) { first.call("add", 1) }
    second = server.hold(SESSION_COUNTER, {session: "S1", name: "a"})
    second.call("add", 2).should eq JSON::Any.new(2_i64)
    attempt.should eq 2
  end

  it "authorizes before resolving and again after" do
    c = Cluster.new
    c.allow = ->(principal : JSON::Any, _host : String) { principal["guest"] != "blocked" }
    blocked = c.browser({guest: "blocked"})
    chord_error(ErrorCode::Forbidden) { blocked.host.hold(SESSION_COUNTER, {session: "S1", name: "a"}).ready.wait }
    c.workers.size.should eq 0
    calls = 0
    c.allow = ->(_principal : JSON::Any, _host : String) { (calls += 1) == 1 }
    flaky = c.browser({guest: "flaky"})
    chord_error(ErrorCode::Forbidden) { flaky.host.hold(SESSION_COUNTER, {session: "S2", name: "a"}).ready.wait }
    calls.should eq 2
  end

  it "a browser disconnect releases exactly its holds; the worker link stays up" do
    c = Cluster.new
    one = c.browser({guest: "g1"})
    two = c.browser({guest: "g2"})
    one.host.hold(SESSION_COUNTER, {session: "S1", name: "a"}).call("add", 1)
    other = two.host.hold(SESSION_COUNTER, {session: "S1", name: "b"})
    other.call("add", 1)
    one.up.close
    eventually { c.log.includes?("close a") }
    c.log.includes?("close b").should be_false
    other.call("add", 1).should eq JSON::Any.new(2_i64)
  end

  it "a dead link (no pongs) is closed and everything held through it is released" do
    c = Cluster.new(LinkOptions.new(ping_interval: 10.milliseconds, ping_timeout: 40.milliseconds))
    browser = c.browser({guest: "g1"})
    browser.host.hold(SESSION_COUNTER, {session: "S1", name: "a"}).call("add", 1)
    browser.up.sever
    eventually { c.log.includes?("close a") }
  end

  it "checks contract tokens across links: contract_mismatch for hosts, upgrade_required for browsers" do
    counter_v2 = C.remote("t.counter", version: 2, input: T.object({name: T.string}), host: C.host_named("server"),
      variants: {main: C.variant(methods: {inc: C.method(nil, T.number)})})
    pair = server_with_worker
    pair.server.serve(counter_v2) { Implementation.new("main").method("inc") { 1 } }
    chord_error(ErrorCode::ContractMismatch) { pair.worker.hold(COUNTER, {name: "x"}).ready.wait }
    down, up = C.memory_link_pair
    pair.server.accept(down, principal: {guest: "g"})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    chord_error(ErrorCode::UpgradeRequired) { browser.hold(COUNTER, {name: "x"}).ready.wait }
  end

  it "invalidate_principal re-stamps the link and propagates to workers" do
    c = Cluster.new
    restamp = ->(principal : JSON::Any) : JSON::Any? do
      fields = principal.as_h.dup
      fields["revision"] = JSON::Any.new(2_i64)
      JSON::Any.new(fields)
    end
    browser = c.browser({guest: "g1", revision: 1}, restamp)
    counter = browser.host.hold(SESSION_COUNTER, {session: "S1", name: "a"})
    counter.call("add", 1)
    c.server.invalidate_principal({guest: "g1"})
    eventually { counter.status.gone? }
    eventually { c.log.includes?("close a") }
    again = browser.host.hold(SESSION_COUNTER, {session: "S1", name: "a"})
    again.call("who").should eq j(%({"guest":"g1","revision":2}))
  end

  it "after a reconnect, state subscribers get a reset and calls work again" do
    c = Cluster.new
    browser = c.browser({guest: "g1"})
    counter = browser.host.hold(SESSION_COUNTER, {session: "S1", name: "r"})
    events = [] of StateEvent::Kind
    counter.state("count").events { |event| events << event.kind }
    counter.call("add", 2)
    browser.up.close
    eventually { counter.status.loading? }
    browser.reconnect
    counter.call("add", 1).should eq JSON::Any.new(1_i64)
    eventually { counter.state("count").value == j(%({"n":1})) }
    events.first.should eq StateEvent::Kind::Snap
    events.should contain StateEvent::Kind::Reset
  end
end

describe "links: methods without arguments or result" do
  it "travel without args and without a value, and resolve to the result or nil" do
    tool = C.remote("t.tool", version: 1, input: T.object, host: C.host_named("server"), variants: {
      main: C.variant(methods: {ping: C.method, count: C.method(nil, T.number), note: C.method(T.string)}),
    })
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    notes = [] of String
    server.serve(tool) do
      Implementation.new("main")
        .method("ping") { nil }
        .method("count") { 2 }
        .method("note") { |text| notes << text.not_nil!.as_s; "dropped" }
    end
    down, up = C.memory_link_pair
    server.accept(down, principal: {guest: "g"})
    link = CountingLink.new(up)
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(link, principal: {kind: "server"}))
    ref = browser.hold(tool)
    ref.ready.wait
    ref.call("ping").should be_nil
    ref.call("count").should eq JSON::Any.new(2_i64)
    ref.call("note", "hi").should be_nil
    notes.should eq ["hi"]
    link.sent.select { |frame| frame.t == "call" }.map(&.payload?).should eq [false, false, true]
  end
end

describe "links: protocol version" do
  it "a peer without a protocol version is told and dropped; nothing it sends is served" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_counter(server)
    seen = [] of Tuple(Int32, Int32?)
    down, raw = C.memory_link_pair
    server.accept(down, principal: {guest: "g"},
      on_protocol_mismatch: ->(local : Int32, peer : Int32?) { seen << {local, peer}; nil })
    frames = [] of Frame
    closed = nil.as(String?)
    raw.receive { |frame| frames << frame }
    raw.on_close { |reason| closed = reason }
    raw_hello(raw, "old", nil)
    raw.send(wire("hold", id: 1, at: "server", token: COUNTER.description.json, input: j(%({"name":"c"}))))
    eventually { !closed.nil? }
    seen.should eq [{PROTOCOL_VERSION, 1}]
    closed.should eq "protocol-version #{PROTOCOL_VERSION}"
    down.closed?.should be_true
    frames.any? { |frame| frame.t == "shape" }.should be_false
  end

  it "a client learns that its server speaks another version, and stops" do
    seen = [] of Tuple(Int32, Int32?)
    mismatch = ->(local : Int32, peer : Int32?) { seen << {local, peer}; nil }
    down, up = C.memory_link_pair
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error)
    browser.connect(up, principal: {kind: "server"}, on_protocol_mismatch: mismatch)
    down.send(wire("hello", protocol: PROTOCOL_VERSION + 1, name: "server", kind: "host", codeVersion: 1))
    eventually { up.closed? }
    seen.should eq [{PROTOCOL_VERSION, PROTOCOL_VERSION + 1}]

    told = [] of Tuple(Int32, Int32?)
    down2, up2 = C.memory_link_pair
    other = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error)
    other.connect(up2, principal: {kind: "server"}, on_protocol_mismatch: ->(local : Int32, peer : Int32?) { told << {local, peer}; nil })
    down2.close("protocol-version #{PROTOCOL_VERSION + 1}")
    eventually { told.size == 1 }
    told.should eq [{PROTOCOL_VERSION, PROTOCOL_VERSION + 1}]
  end

  it "peers of the same version talk; an ordinary close is no mismatch" do
    seen = [] of Tuple(Int32, Int32?)
    mismatch = ->(local : Int32, peer : Int32?) { seen << {local, peer}; nil }
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, up = C.memory_link_pair
    server.accept(down, principal: {guest: "g"}, on_protocol_mismatch: mismatch)
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error)
    browser.connect(up, principal: {kind: "server"}, on_protocol_mismatch: mismatch)
    tick
    up.close("bye")
    tick
    seen.should be_empty
  end
end

describe "links: packed payloads" do
  it "large args, results and snapshots cross a relay deflated and arrive intact" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        down, up = C.memory_link_pair
        worker = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
          upstream: C.upstream(up, principal: {kind: "server"}))
        worker.serve(BIG) do |_input, _principal, scope|
          notes = scope.state("notes", T.array(T.string), large("a"))
          Implementation.new("main").state("notes", notes).method("echo") { |given| given }
        end
        down
      end,
    ))
    down, up = C.memory_link_pair
    server.accept(down, principal: {owner: true})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    big = browser.hold(BIG)
    big.call("echo", large("c")).should eq large("c")
    big.state("notes").subscribe { }
    eventually { big.status.live? }
    big.state("notes").value.should eq large("a")
  end

  it "only payloads above the threshold are packed; the receiver unpacks them" do
    a, b = C.memory_link_pair
    frames = [] of Frame
    b.receive { |frame| frames << frame }
    a.send(wire("result", id: 1, value: large("v")))
    a.send(wire("result", id: 2, value: j(%(["small"]))))
    a.send(Frame.state(3, "notes", "snap", value: large("s")))
    eventually { frames.size == 3 }
    packed, small, snap = frames[0], frames[1], frames[2]
    packed.packed.should_not be_nil
    packed.payload.should eq large("v")
    small.packed.should be_nil
    small.payload.should eq j(%(["small"]))
    snap.packed.should_not be_nil
    snap.payload.should eq large("s")

    c, d = C.memory_link_pair
    forwarded = [] of Frame
    d.receive { |frame| forwarded << frame }
    c.send(packed.with("id", JSON::Any.new(9_i64)))
    eventually { forwarded.size == 1 }
    forwarded[0].packed.not_nil!.bytes.should eq packed.packed.not_nil!.bytes
  end
end

private class BrokenPipe < IO
  @never = Channel(Nil).new

  def read(slice : Bytes) : Int32
    @never.receive
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.from_os_error("write", Errno::EPIPE)
  end
end

describe "links: IPC" do
  it "a write that fails after the peer process exited (EPIPE) ends the link" do
    link = C.ipc_link(IpcChannel.new(BrokenPipe.new))
    reasons = [] of String
    link.on_close { |reason| reasons << reason }
    link.send(wire("ping", n: 1))
    eventually { link.closed? }
    reasons.should eq ["ipc send failed: EPIPE"]
    link.send(wire("ping", n: 2)).should be_nil
  end

  it "frames cross a socket pair as line-delimited JSON wrapped in chord2" do
    left, right = UNIXSocket.pair
    a = C.ipc_link(IpcChannel.new(left))
    lines = Channel(String).new(1)
    spawn { lines.send(right.gets.not_nil!) }
    a.send(wire("ping", n: 7))
    JSON.parse(lines.receive).should eq j(%({"chord2":{"t":"ping","n":7}}))
    received = [] of Frame
    a.receive { |frame| received << frame }
    right << %({"chord2control":{"type":"ready"}}\n{"chord2":{"t":"pong","n":7}}\n)
    right.flush
    eventually { received.size == 1 }
    received[0].fields.should eq({"t" => JSON::Any.new("pong"), "n" => JSON::Any.new(7_i64)})
    right.close
    eventually { a.closed? }
  end
end
