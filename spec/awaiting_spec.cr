# spec/awaiting_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private SLOW = C.remote("t.e8-slow", version: 1, input: T.object, host: C.host_named("server"),
  variants: {main: C.variant(state: {n: T.number})})

private record AwaitSetup, server : Host, browser : Host, link : CountingLink, open : Channel(Nil)

private def setup(ready_timeout : Time::Span? = 60.seconds) : AwaitSetup
  opened = Channel(Nil).new
  gate_open = false
  server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
  server.serve(SLOW) do |_input, _principal, scope|
    scope.resource("gate", version: 1) { opened.receive unless gate_open; gate_open = true; nil }
    Implementation.new("main").state("n", scope.state("n", T.number, 1))
  end
  down, up = C.memory_link_pair
  server.accept(down, principal: {user: "u"})
  link = CountingLink.new(up)
  browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
    ready_timeout: ready_timeout, upstream: C.upstream(link, principal: {kind: "server"}))
  AwaitSetup.new(server, browser, link, opened)
end

private def open_gate(s : AwaitSetup) : Nil
  spawn { s.open.send(nil) }
end

describe "awaited gets" do
  it "an aborted get rejects and releases only its reference; the binding stays for the others" do
    s = setup
    abort = AbortController.new
    first = Future(Ref).run { s.browser.get(SLOW, nil, signal: abort.signal) }
    second = Future(Ref).run { s.browser.get(SLOW) }
    sleep 5.milliseconds
    abort.abort
    expect_raises(ChordError) { first.wait }.code.should eq ErrorCode::Aborted
    sleep 5.milliseconds
    s.link.count(:sent, "release").should eq 0
    open_gate(s)
    ref = second.wait
    ref.state("n").value.should eq JSON::Any.new(1_i64)
    s.link.count(:sent, "hold").should eq 1
    ref.release
    eventually { s.link.count(:sent, "release") == 1 }
    s.server.close
  end

  it "a ctx.get still waiting when its call settles rejects aborted and releases its reference" do
    s = setup
    pending = nil.as(Future(Ref)?)
    s.browser.root do |ctx|
      pending = Future(Ref).run { ctx.get(SLOW) }
      Fiber.yield
    end
    expect_raises(ChordError) { pending.not_nil!.wait }.code.should eq ErrorCode::Aborted
    eventually { s.link.count(:sent, "release") == 1 }
    open_gate(s)
    s.server.close
  end

  it "a get times out after ready_timeout with ready_timeout and releases its hold" do
    s = setup(30.milliseconds)
    error = expect_raises(ChordError) { s.browser.get(SLOW) }
    error.code.should eq ErrorCode::Unavailable
    error.reason.should eq "ready_timeout"
    eventually { s.link.count(:sent, "release") == 1 }
    open_gate(s)
    s.server.close
  end

  it "ctx.get resolves hydrated; the call's reference is released when the call ends" do
    s = setup
    open_gate(s)
    value = s.browser.root { |ctx| ctx.get(SLOW).state("n").value }
    value.should eq JSON::Any.new(1_i64)
    eventually { s.link.count(:sent, "release") == 1 }
    s.server.close
  end
end
