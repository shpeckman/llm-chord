# spec/links_review_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private COUNTER = C.remote("t.counter", version: 1, input: T.object({name: T.string}), host: C.host_named("session:S1"),
  variants: {
    main: C.variant(state: {count: T.object({n: T.number})},
      methods: {add: C.method(T.number, T.number), who: C.method(nil, T.unknown), slow: C.method}),
  })

private class WatchedLink < LLM::Chord::Link
  getter sent = [] of Frame

  def initialize(@inner : LLM::Chord::Link); end

  def closed? : Bool
    @inner.closed?
  end

  def send(frame : Frame) : Int32?
    @sent << frame
    @inner.send(frame)
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

private class ReviewCluster
  getter server : Host
  getter log = [] of String
  getter principals = [] of JSON::Any
  getter workers = {} of String => Tuple(Host, WatchedLink)
  property resolve_gate : Channel(Nil)? = nil
  getter slow_gate = Channel(Nil).new

  def initialize
    @server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    cluster = self
    @server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) { cluster.resolve(name) },
    ))
  end

  def resolve(name : String) : LLM::Chord::Link
    @resolve_gate.try &.receive
    if existing = @workers[name]?
      return existing[1]
    end
    down, up = C.memory_link_pair
    link = WatchedLink.new(down)
    worker = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    log = @log
    principals = @principals
    slow_gate = @slow_gate
    worker.serve(COUNTER) do |input, principal, scope|
      principals << principal
      tag = input["name"].as_s
      scope.resource("probe", version: 1, close: ->(_value : Nil) { log << "close #{tag}"; nil }) { log << "open #{tag}"; nil }
      count = scope.state("count", T.object({n: T.number}), {n: 0})
      Implementation.new("main")
        .state("count", count)
        .method("add") do |delta, ctx|
          count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i }
          count.value["n"]
        end
        .method("who") { principal }
        .method("slow") do |_args, ctx|
          ctx.signal.on_abort { log << "slow aborted" }
          select
          when slow_gate.receive
          when timeout(2.seconds)
          end
          nil
        end
    end
    @workers[name] = {worker, link}
    link
  end

  def browser(principal, restamp : Proc(JSON::Any, JSON::Any?)? = nil) : Tuple(Host, MemoryLink)
    down, up = C.memory_link_pair
    if restamp
      @server.accept(down, principal: principal, restamp: restamp)
    else
      @server.accept(down, principal: principal)
    end
    host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    {host, up}
  end

  def raw(principal) : Tuple(MemoryLink, Array(Frame))
    down, raw = C.memory_link_pair
    @server.accept(down, principal: principal)
    frames = [] of Frame
    raw.receive { |frame| frames << frame }
    raw.send(wire("hello", protocol: PROTOCOL_VERSION, name: "raw", kind: "client", codeVersion: 0))
    {raw, frames}
  end

  def worker_connection : Connection
    @server.connections.find! { |connection| connection.peer.name == "session:S1" }
  end
end

describe "links review: identity and stamping" do
  it "the acceptor decides what a peer is: a client announcing itself as a host is cut off" do
    c = ReviewCluster.new
    down, raw = C.memory_link_pair
    c.server.accept(down, principal: {guest: "g"})
    raw.receive { }
    raw.send(wire("hello", protocol: PROTOCOL_VERSION, name: "session:S1", kind: "host", codeVersion: 1))
    eventually { raw.closed? }
    expect_raises(ArgumentError, /needs its name/) { c.server.accept(C.memory_link_pair[0], principal: j("{}"), kind: :host) }
  end

  it "a revocation while the route is still resolving closes the relay; no worker object is made" do
    c = ReviewCluster.new
    gate = Channel(Nil).new
    c.resolve_gate = gate
    restamp = ->(principal : JSON::Any) : JSON::Any? do
      fields = principal.as_h.dup
      fields["revision"] = JSON::Any.new(2_i64)
      JSON::Any.new(fields)
    end
    host, _up = c.browser({guest: "g", revision: 1}, restamp)
    counter = host.hold(COUNTER, {name: "a"})
    sleep 5.milliseconds
    c.server.invalidate_principal({guest: "g"})
    eventually { counter.status.gone? }
    c.resolve_gate = nil
    gate.send(nil)
    sleep 10.milliseconds
    c.principals.should be_empty
    again = host.hold(COUNTER, {name: "a"})
    again.call("who").should eq j(%({"guest":"g","revision":2}))
  end

  it "malformed frames and duplicate ids close the link" do
    c = ReviewCluster.new
    first, _ = c.raw({guest: "g"})
    first.send(Frame.new({"t" => JSON::Any.new("call"), "hold" => JSON::Any.new(1_i64)}))
    eventually { first.closed? }
    second, _ = c.raw({guest: "g"})
    token = COUNTER.description.json
    second.send(wire("hold", id: 1, at: "session:S1", token: token, input: j(%({"name":"a"}))))
    second.send(wire("hold", id: 1, at: "session:S1", token: token, input: j(%({"name":"b"}))))
    eventually { second.closed? }
  end
end

describe "links review: relay ownership" do
  it "a browser disconnect cancels its call downstream" do
    c = ReviewCluster.new
    host, up = c.browser({guest: "g"})
    counter = host.hold(COUNTER, {name: "a"})
    counter.ready.wait
    spawn { counter.call("slow") rescue nil }
    sleep 10.milliseconds
    up.close
    eventually { c.log.includes?("slow aborted") }
    eventually { c.worker_connection.relayed_calls.empty? }
  end

  it "state stopped while the route resolves is forwarded as a hold without state" do
    c = ReviewCluster.new
    gate = Channel(Nil).new
    c.resolve_gate = gate
    raw, _ = c.raw({guest: "g"})
    raw.send(wire("hold", id: 1, at: "session:S1", token: COUNTER.description.json, input: j(%({"name":"a"}))))
    raw.send(wire("unsub", hold: 1))
    sleep 5.milliseconds
    c.resolve_gate = nil
    gate.send(nil)
    eventually { c.workers["session:S1"]?.try(&.[1].sent.any? { |frame| frame.t == "hold" }) == true }
    sleep 10.milliseconds
    sent = c.workers["session:S1"][1].sent
    sent.find!(&.t.==("hold"))["state"]?.should eq JSON::Any.new(false)
    sent.any? { |frame| frame.t == "sub" || frame.t == "unsub" }.should be_false
  end

  it "a release while the route resolves settles waiting calls and forwards nothing" do
    c = ReviewCluster.new
    gate = Channel(Nil).new
    c.resolve_gate = gate
    raw, frames = c.raw({guest: "g"})
    raw.send(wire("hold", id: 1, at: "session:S1", token: COUNTER.description.json, input: j(%({"name":"a"}))))
    raw.send(wire("call", id: 2, hold: 1, member: "add", args: JSON::Any.new(1_i64)))
    sleep 5.milliseconds
    raw.send(wire("release", id: 1))
    eventually { frames.any? { |frame| frame.t == "result" && frame.int("id") == 2 } }
    frames.find! { |frame| frame.t == "result" && frame.int("id") == 2 }["error"]?.should_not be_nil
    c.resolve_gate = nil
    gate.send(nil)
    sleep 10.milliseconds
    (c.workers["session:S1"]?.try(&.[1].sent) || [] of Frame).any? { |frame| frame.t == "hold" }.should be_false
  end

  it "an origin disconnect removes its relayed holds and subscriptions downstream" do
    c = ReviewCluster.new
    host, up = c.browser({guest: "g"})
    counter = host.hold(COUNTER, {name: "a"})
    counter.state("count").subscribe { }
    counter.call("add", 1)
    c.worker_connection.relayed_refs.size.should eq 1
    up.close
    eventually { c.worker_connection.relayed_refs.empty? }
    eventually { c.log.includes?("close a") }
  end

  it "two browsers share one worker connection; one leaving releases only its own holds" do
    c = ReviewCluster.new
    one, one_up = c.browser({guest: "g1"})
    two, _ = c.browser({guest: "g2"})
    a = one.hold(COUNTER, {name: "same"})
    b = two.hold(COUNTER, {name: "same"})
    a.call("add", 1).should eq JSON::Any.new(1_i64)
    b.call("add", 5).should eq JSON::Any.new(5_i64)
    c.workers.size.should eq 1
    c.principals.should eq [j(%({"guest":"g1"})), j(%({"guest":"g2"}))]
    one_up.close
    eventually { c.log.count("close same") == 1 }
    b.call("add", 1).should eq JSON::Any.new(6_i64)
  end

  it "snapshots through an accepts adapter are validated against the consumer's schema" do
    doc_v1 = C.remote("t.doc", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(state: {view: T.object({text: T.string})})})
    doc_v2 = C.remote("t.doc", version: 2, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(state: {view: T.object({body: T.string})})})
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    adapter = ->(current : Implementation) do
      Implementation.new("main").state("view", Mapped.new(current["view"].as(Readable)))
    end
    server.serve(doc_v2, accepts: {1 => adapter}) do |_input, _principal, scope|
      Implementation.new("main").state("view", scope.state("view", T.object({body: T.string}), {body: "hi"}))
    end
    down, up = C.memory_link_pair
    server.accept(down, principal: {guest: "g"})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    doc = browser.hold(doc_v1)
    doc.ready.wait
    doc.state("view").value.should eq j(%({"text":"hi"}))
  end
end

private class Mapped < Readable
  def initialize(@inner : Readable); end

  def value : JSON::Any
    JSON::Any.new({"text" => @inner.value["body"]})
  end

  def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
    forward_values(listener)
  end

  def events(&listener : StateEvent -> Nil) : Proc(Nil)
    forward_events(listener)
  end

  private def forward_values(listener : Proc(JSON::Any, Nil)) : Proc(Nil)
    @inner.events { listener.call(value) }
  end

  private def forward_events(listener : Proc(StateEvent, Nil)) : Proc(Nil)
    @inner.events do |event|
      listener.call(event.kind.ops? ? StateEvent.reset(value) : StateEvent.new(event.kind, value))
    end
  end
end

describe "review: remote ctx races" do
  it "a remote reference refuses a foreign ctx without calling" do
    target_contract = C.remote("t.remote-target", version: 1, input: T.object, host: C.host_named("server"),
      variants: {main: C.variant(methods: {hit: C.method})})
    hits = 0
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(target_contract) { Implementation.new("main").method("hit") { hits += 1; nil } }
    down, up = C.memory_link_pair
    server.accept(down, kind: :host, name: "worker", principal: {worker: true})
    link = CountingLink.new(up)
    worker = Host.new(self: {kind: "host"}, name: "worker", on_error: quiet_on_error)
    worker.connect(link, principal: {kind: "server"})
    other = Host.new(self: {kind: "host"}, name: "other", on_error: quiet_on_error)
    target = worker.hold(target_contract)
    target.ready.wait
    error = other.root do |ctx|
      begin
        target.call("hit", ctx)
        nil
      rescue failure : ChordError
        failure
      end
    end
    error.not_nil!.code.should eq ErrorCode::Invalid
    error.not_nil!.reason.should eq "foreign_ctx"
    tick
    hits.should eq 0
    link.count(:sent, "call").should eq 0
    worker.root { |ctx| target.call("hit", ctx) }
    hits.should eq 1
  end

  it "an expired ctx is refused" do
    target_contract = C.local("t.target", version: 1, input: T.object, members: {hit: C.method})
    host = Host.new(self: {kind: "host"}, on_error: quiet_on_error)
    host.serve(target_contract) { Implementation.new.method("hit") { nil } }
    target = host.hold(target_contract)
    target.ready.wait
    expired = host.root { |ctx| ctx }
    error = expect_raises(ChordError) { target.call("hit", expired) }
    error.code.should eq ErrorCode::Aborted
    error.reason.should eq "expired"
  end
end
