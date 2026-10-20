# spec/flow_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private def counter_on(name : String, host : String) : RemoteContract
  C.remote(name, version: 1, input: T.object, host: C.host_named(host), variants: {
    main: C.variant(state: {count: T.object({n: T.number})}, methods: {add: C.method(T.number, T.number), wait: C.method}),
  })
end

private COUNTER        = counter_on("t.flow-counter", "server")
private WORKER_COUNTER = counter_on("t.flow-worker-counter", "w")

private class Gate
  @waiters = [] of Channel(Nil)

  def wait : Nil
    channel = Channel(Nil).new(1)
    @waiters << channel
    channel.receive
  end

  def open : Nil
    @waiters.each { |channel| channel.send(nil) }
    @waiters.clear
  end
end

private def serve_counter(host : Host, gate : Gate, type : RemoteContract = COUNTER) : Nil
  host.serve(type) do |_input, _principal, scope|
    count = scope.state("count", T.object({n: T.number}), {n: 0})
    Implementation.new("main")
      .state("count", count)
      .method("add") do |delta, ctx|
        count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i }
        count.value["n"]
      end
      .method("wait") { gate.wait }
  end
end

private def client(server : Host, window : Int64) : Tuple(Host, CountingLink)
  down, up = C.memory_link_pair
  server.accept(down, principal: {user: "u"}, window: window)
  gate = CountingLink.new(up)
  host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
    upstream: C.upstream(gate, principal: {kind: "server"}))
  {host, gate}
end

private def last_n(values : Array(JSON::Any)) : Int64
  values.last?.try(&.["n"]?.try(&.as_i64)) || -1_i64
end

describe "link flow control" do
  it "holds state back while the window is full, answers calls meanwhile, and sends one coalesced frame" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_counter(server, Gate.new)
    host, gate = client(server, 200)
    counter = host.hold(COUNTER)
    values = [] of JSON::Any
    counter.state("count").subscribe { |value| values << value }
    eventually { !values.empty? }
    gate.paused = true
    results = (1..40).map { counter.call("add", 1).not_nil!.as_i64 }
    results.last.should eq 40
    (last_n(values) < 40).should be_true
    before = state_frames(gate.received).size
    gate.release
    eventually { last_n(values) == 40 }
    (state_frames(gate.received).size - before).should eq 1
    host.close
    server.close
  end

  it "replaces ops that outgrow their slot with the current value" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_counter(server, Gate.new)
    host, gate = client(server, 64)
    counter = host.hold(COUNTER)
    values = [] of JSON::Any
    counter.state("count").subscribe { |value| values << value }
    eventually { !values.empty? }
    gate.paused = true
    before = gate.received.size
    100.times { counter.call("add", 1) }
    gate.release
    eventually { last_n(values) == 100 }
    sent = state_frames(gate.received[before..])
    sent.any? { |frame| frame.string("as") == "reset" }.should be_true
    (sent.size < 10).should be_true
    host.close
    server.close
  end

  it "drops what waits for a reference that is released" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_counter(server, Gate.new)
    host, gate = client(server, 64)
    counter = host.hold(COUNTER)
    counter.ready.wait
    other = host.hold(COUNTER)
    other.ready.wait
    gate.paused = true
    10.times { counter.call("add", 1) }
    counter.release
    other.release
    before = gate.received.size
    gate.release
    sleep 10.milliseconds
    state_frames(gate.received[before..]).should be_empty
    host.close
    server.close
  end

  it "coalesces relayed state for the origin and asks downstream for a reset when it overflows" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    to_worker = nil.as(CountingLink?)
    server.route("w", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        down, up = C.memory_link_pair
        worker = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
          upstream: C.upstream(up, principal: {kind: "server"}))
        serve_counter(worker, Gate.new, WORKER_COUNTER)
        link = CountingLink.new(down)
        to_worker = link
        link.as(LLM::Chord::Link)
      end,
    ))
    host, gate = client(server, 64)
    counter = host.hold(WORKER_COUNTER)
    values = [] of JSON::Any
    counter.state("count").subscribe { |value| values << value }
    eventually { !values.empty? }
    resyncs = -> { to_worker.not_nil!.count(:sent, "resync") }
    resyncs.call.should eq 0
    gate.paused = true
    100.times { counter.call("add", 1) }
    (resyncs.call >= 1).should be_true
    to_worker.not_nil!.sent.any? { |frame| frame.t == "sub" || frame.t == "unsub" }.should be_false
    gate.release
    eventually { last_n(values) == 100 }
    host.close
    server.close
  end

  it "neither windows nor acknowledges a peer whose hello does not announce acks" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_counter(server, Gate.new)
    down, raw = C.memory_link_pair
    server.accept(down, principal: {user: "u"}, window: 1)
    frames = [] of Frame
    raw.receive { |frame| frames << frame }
    raw.send(wire("hello", protocol: PROTOCOL_VERSION, name: "raw", kind: "client", codeVersion: 0))
    raw.send(wire("hold", id: 1, at: "server", token: COUNTER.description.json, input: j("{}")))
    5.times { |i| raw.send(wire("call", id: 3 + i, hold: 1, member: "add", args: JSON::Any.new(1_i64))) }
    eventually { frames.count { |frame| frame.t == "result" } == 5 }
    sleep 5.milliseconds
    state_frames(frames).size.should eq 6
    frames.any? { |frame| frame.t == "ack" }.should be_false
    frames[0]["acks"].should eq JSON::Any.new(true)
    server.close
  end

  it "closes the link on an acknowledgement of frames never sent" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, raw = C.memory_link_pair
    server.accept(down, principal: {user: "u"})
    raw.receive { }
    raw.send(wire("hello", name: "raw", kind: "client", codeVersion: 0, acks: true))
    raw.send(wire("ack", n: 99))
    eventually { raw.closed? }
    server.close
  end
end

describe "link call limit" do
  it "answers calls beyond max_calls at once with too_many_calls and keeps the link" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    gate = Gate.new
    serve_counter(server, gate)
    down, up = C.memory_link_pair
    server.accept(down, principal: {user: "u"}, max_calls: 2)
    host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    counter = host.hold(COUNTER)
    counter.ready.wait
    first = Future(JSON::Any?).run { counter.call("wait") }
    second = Future(JSON::Any?).run { counter.call("wait") }
    sleep 5.milliseconds
    error = expect_raises(ChordError) { counter.call("add", 1) }
    error.code.should eq ErrorCode::Unavailable
    error.reason.should eq "too_many_calls"
    gate.open
    first.wait
    second.wait
    counter.call("add", 1).should eq JSON::Any.new(1_i64)
    host.close
    server.close
  end
end
