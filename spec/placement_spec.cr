# spec/placement_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private NOTE = C.remote("t.note", version: 1, input: T.object({session: T.string, id: T.string}),
  host: C.host_family("session:", "session"),
  variants: {main: C.variant(methods: {where: C.method(nil, T.string)})})

private CATALOG = C.remote("t.catalog", version: 1, input: T.object, host: C.host_named("server"),
  variants: {main: C.variant(methods: {where: C.method(nil, T.string)})})

private class PlacementCluster
  getter server : Host
  getter children = {} of String => Host
  @links = {} of String => LLM::Chord::Link

  def initialize
    @server = Host.new(name: "server", self: "host", on_error: quiet_on_error)
    @server.serve(CATALOG) { Implementation.new("main").method("where") { "server" } }
    child("session:S1")
    child("session:S2")
    links = @links
    @server.route("session:", Route.new(
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) { links[name] },
      principal: ->(name : String) { name },
    ))
  end

  def s1 : Host
    @children["session:S1"]
  end

  def close : Nil
    @children.each_value(&.close)
    @server.close
  end

  private def child(name : String) : Nil
    down, up = C.memory_link_pair
    @links[name] = down
    @server.accept(down, kind: :host, name: name, principal: "server-side")
    host = Host.new(name: name, self: "host", on_error: quiet_on_error, upstream: C.upstream(up, principal: "server"))
    host.serve(NOTE) { |input| Implementation.new("main").method("where") { "#{name} #{input["id"]}" } }
    @children[name] = host
  end
end

private def first_reply(server : Host, target : String, input : JSON::Any) : Frame?
  down, raw = C.memory_link_pair
  server.accept(down, principal: "guest")
  frames = [] of Frame
  raw.receive { |frame| frames << frame }
  raw.send(wire("hello", protocol: PROTOCOL_VERSION, name: "raw", kind: "client", codeVersion: 0))
  raw.send(wire("hold", id: 1, at: target, token: NOTE.description.json, input: input))
  eventually { frames.any? { |frame| frame.t == "shape" || frame.t == "gone" } }
  frames.find { |frame| frame.t == "shape" || frame.t == "gone" }
end

describe "placement" do
  it "a get goes where the contract places the input: here, a child, or the parent" do
    c = PlacementCluster.new
    tick
    c.server.hold(NOTE, {session: "S1", id: "a"}).call("where").should eq JSON::Any.new("session:S1 a")
    c.server.hold(NOTE, {session: "S2", id: "b"}).call("where").should eq JSON::Any.new("session:S2 b")
    c.s1.hold(NOTE, {session: "S1", id: "c"}).call("where").should eq JSON::Any.new("session:S1 c")
    c.s1.hold(CATALOG).call("where").should eq JSON::Any.new("server")
    c.close
  end

  it "serve refuses a type the host is not the place of" do
    host = Host.new(name: "session:S1", self: "host", on_error: quiet_on_error)
    expect_raises(ArgumentError, /t\.catalog is declared for server, but session:S1 serves it/) do
      host.serve(CATALOG) { Implementation.new("main") }
    end
    server = Host.new(name: "server", self: "host", on_error: quiet_on_error)
    expect_raises(ArgumentError, /t\.note is declared for session:<session>, but server serves it/) do
      server.serve(NOTE) { Implementation.new("main") }
    end
  end

  it "a host refuses a hold its own contract places elsewhere, and a relay one whose target disagrees" do
    c = PlacementCluster.new
    tick
    relayed = first_reply(c.server, "session:S2", j(%({"session":"S1","id":"x"}))).not_nil!
    relayed.t.should eq "gone"
    relayed["error"]["message"].as_s.should match(/placement|does not live on session:S2/)
    first_reply(c.server, "session:S1", j(%({"session":"S1","id":"x"}))).not_nil!.t.should eq "shape"
    first_reply(c.server, "server", j(%({"session":"S1","id":"x"}))).not_nil!.t.should eq "gone"
    c.close
  end

  it "the host comes from the normalized input: unknown fields and defaults do not change it" do
    doc = C.remote("t.doc-default", version: 1, input: T.object({session: T.string(default: "S1")}),
      host: C.host_family("session:", "session"),
      variants: {main: C.variant(methods: {where: C.method(nil, T.string)})})
    c = PlacementCluster.new
    c.s1.serve(doc) { Implementation.new("main").method("where") { "session:S1" } }
    tick
    c.server.hold(doc, j("{}")).call("where").should eq JSON::Any.new("session:S1")
    expect_raises(ChordError, /input field session names no host/) { c.server.hold(NOTE, {session: "", id: "x"}) }
    c.close
  end
end
