# spec/flow_units_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private BLOB = C.remote("t.e8-blob", version: 1, input: T.object({name: T.string}), host: C.host_named("server"),
  variants: {
    main: C.variant(state: {lines: T.array(T.string)}, methods: {push: C.method(T.string), ping: C.method(nil, T.string)}),
  })

private def lines(kib : Int32, tag : String) : Array(JSON::Any)
  (0...kib).map { |index| JSON::Any.new("#{tag}#{index}:#{"x" * 1000}") }
end

private def serve_blob(host : Host, &size : String -> Int32) : Nil
  host.serve(BLOB) do |input, _principal, scope|
    name = input["name"].as_s
    state = scope.state("lines", T.array(T.string), lines(size.call(name), name))
    Implementation.new("main")
      .state("lines", state)
      .method("push") { |line, ctx| state.change(ctx) { |draft| draft << line.not_nil! } }
      .method("ping") { "pong" }
  end
end

private def client(server : Host, window : Int64, pending_cap : Int64? = nil) : Tuple(Host, CountingLink)
  down, up = C.memory_link_pair
  server.accept(down, principal: {user: "u"}, window: window, pending_cap: pending_cap)
  link = CountingLink.new(up)
  host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
    upstream: C.upstream(link, principal: {kind: "server"}))
  {host, link}
end

private def line_count(ref : Ref) : Int32
  ref.state("lines").value.as_a.size
end

private class Unsized < LLM::Chord::Link
  def initialize(@inner : LLM::Chord::Link); end

  def closed? : Bool
    @inner.closed?
  end

  def send(frame : Frame) : Int32?
    @inner.send(frame)
    nil
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

describe "flow control with units" do
  it "with large streams waiting behind a full window, a new get resolves at once and calls are answered" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_blob(server) { |name| name == "small" ? 1 : 500 }
    host, link = client(server, 64_i64 * 1024)
    bigs = %w[a b c].map { |name| host.hold(BLOB, {name: name}) }
    bigs.each(&.ready.wait)
    link.paused = true
    bigs.each { |big| 50.times { |i| big.call("push", "#{i}:#{"y" * 2000}") } }
    small = host.hold(BLOB, {name: "small"})
    small.ready.wait
    line_count(small).should eq 1
    bigs[0].call("ping").should eq JSON::Any.new("pong")
    (line_count(bigs[0]) < 550).should be_true
    link.release
    eventually(5.seconds) { bigs.all? { |big| line_count(big) == 550 } }
    server.close
  end

  it "a snapshot larger than the window arrives whole; later changes wait for acknowledgements" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_blob(server) { 300 }
    host, link = client(server, 16_i64 * 1024)
    link.paused = true
    big = host.hold(BLOB, {name: "chat"})
    big.ready.wait
    line_count(big).should eq 300
    40.times { |i| big.call("push", "#{i}:#{"z" * 1000}") }
    (line_count(big) < 340).should be_true
    link.release
    eventually { line_count(big) == 340 }
    server.close
  end

  it "a link that reports no sizes (IPC) never holds state back" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_blob(server) { 1 }
    down, up = C.memory_link_pair
    server.accept(Unsized.new(down), principal: {user: "u"}, window: 1)
    link = CountingLink.new(up)
    host = Host.new(self: {kind: "host"}, name: "worker", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(link, principal: {kind: "server"}))
    link.paused = true
    blob = host.hold(BLOB, {name: "x"})
    blob.ready.wait
    20.times { |i| blob.call("push", i.to_s) }
    eventually { line_count(blob) == 21 }
    server.close
  end

  it "waiting ops stay under the per-link cap however many streams stall; each then gets one reset" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    serve_blob(server) { 1 }
    cap = 8_i64 * 1024
    host, link = client(server, 1024, cap)
    connection = -> { server.connections.find!(&.role.downstream?) }
    blobs = (0...6).map { |i| host.hold(BLOB, {name: "s#{i}"}) }
    blobs.each(&.ready.wait)
    link.paused = true
    peak = 0_i64
    30.times do |round|
      blobs.each { |blob| blob.call("push", "#{round}:#{"w" * 200}") }
      peak = Math.max(peak, connection.call.waiting[:bytes])
    end
    (peak <= cap).should be_true
    before = link.received.size
    link.release
    eventually { blobs.all? { |blob| line_count(blob) == 31 } }
    resets = state_frames(link.received[before..]).select { |frame| frame.string("as") == "reset" }
    (resets.size >= 1).should be_true
    resets.group_by(&.int("hold")).each_value { |frames| (frames.size <= 2).should be_true }
    server.close
  end
end

describe "relay topology" do
  counter = C.remote("t.e8-relayed", version: 1, input: T.object({session: T.string}),
    host: C.host_family("session:", "session"),
    variants: {main: C.variant(state: {n: T.number}, methods: {add: C.method(T.number)})})

  it "each origin hold is one downstream hold; nothing is left after release, close or revoke" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    worker = nil.as(Host?)
    to_worker = nil.as(CountingLink?)
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        if to_worker.nil?
          down, up = C.memory_link_pair
          created = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
            upstream: C.upstream(up, principal: {kind: "server"}))
          created.serve(counter) do |_input, _principal, scope|
            n = scope.state("n", T.number, 0)
            Implementation.new("main").state("n", n).method("add") { |delta, ctx| n.replace(ctx, n.value.as_i + delta.not_nil!.as_i) }
          end
          worker = created
          to_worker = CountingLink.new(down)
        end
        to_worker.not_nil!.as(LLM::Chord::Link)
      end,
    ))
    browser = ->(principal : JSON::Any) do
      down, up = C.memory_link_pair
      server.accept(down, principal: principal)
      host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
        upstream: C.upstream(up, principal: {kind: "server"}))
      {host, up}
    end
    served = -> { worker.try(&.upstream).try(&.served.size) || 0 }
    relayed = -> { server.connections.select(&.peer.kind.host?).sum(&.relayed_refs.size) }
    one = browser.call(j(%({"guest":"g"})))
    two = browser.call(j(%({"guest":"g"})))
    three = browser.call(j(%({"guest":"h"})))
    a = one[0].hold(counter, {session: "S1"})
    a2 = one[0].hold(counter, {session: "S1"})
    b = two[0].hold(counter, {session: "S1"})
    d = three[0].hold(counter, {session: "S1"})
    [a, a2, b, d].each(&.ready.wait)
    to_worker.not_nil!.count(:sent, "hold").should eq 3
    served.call.should eq 3
    a.release
    a2.release
    eventually { served.call == 2 && relayed.call == 2 }
    two[1].close
    eventually { served.call == 1 && relayed.call == 1 }
    server.invalidate_principal({guest: "h"})
    eventually { served.call == 0 && relayed.call == 0 }
    server.close
  end

  it "a stalled tab overflows and gets a reset while another tab keeps getting every change" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    to_worker = nil.as(CountingLink?)
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        if to_worker.nil?
          down, up = C.memory_link_pair
          created = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
            upstream: C.upstream(up, principal: {kind: "server"}))
          created.serve(counter) do |_input, _principal, scope|
            n = scope.state("n", T.number, 0)
            Implementation.new("main").state("n", n).method("add") { |delta, ctx| n.replace(ctx, n.value.as_i + delta.not_nil!.as_i) }
          end
          to_worker = CountingLink.new(down)
        end
        to_worker.not_nil!.as(LLM::Chord::Link)
      end,
    ))
    slow_down, slow_up = C.memory_link_pair
    server.accept(slow_down, principal: {guest: "g"}, window: 256, pending_cap: 512)
    slow_link = CountingLink.new(slow_up)
    slow = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(slow_link, principal: {kind: "server"}))
    fast_down, fast_up = C.memory_link_pair
    server.accept(fast_down, principal: {guest: "g"})
    fast = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(fast_up, principal: {kind: "server"}))
    stalled = slow.hold(counter, {session: "S1"})
    live = fast.hold(counter, {session: "S1"})
    stalled.ready.wait
    live.ready.wait
    slow_link.paused = true
    seen = [] of JSON::Any
    live.state("n").subscribe { |value| seen << value }
    200.times { live.call("add", 1) }
    eventually { live.state("n").value == JSON::Any.new(200_i64) }
    (seen.size > 100).should be_true
    (stalled.state("n").value.as_i < 200).should be_true
    (to_worker.not_nil!.count(:sent, "resync") >= 1).should be_true
    slow_link.release
    eventually { stalled.state("n").value == JSON::Any.new(200_i64) }
    server.close
  end
end
