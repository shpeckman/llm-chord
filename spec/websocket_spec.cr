# spec/websocket_spec.cr
require "./spec_helper"
require "http/server"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private BOARD = C.remote("t.board", version: 1, input: T.object, host: C.host_named("server"), variants: {
  main: C.variant(state: {notes: T.array(T.string)}, methods: {add: C.method(T.string), who: C.method(nil, T.unknown)}),
})

private def listen(handler : HTTP::Handler) : Tuple(HTTP::Server, Int32)
  server = HTTP::Server.new([handler])
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  {server, address.port}
end

private def timeout_signal(span : Time::Span) : AbortSignal
  controller = AbortController.new
  spawn { sleep span; controller.abort(ChordError.new(ErrorCode::Aborted, "timed out")) }
  controller.signal
end

private def browser(port : Int32, token : String, name : String = "browser", kind : PeerKind = PeerKind::Client) : Host
  link = WebSocketLink.connect("ws://127.0.0.1:#{port}/?token=#{token}")
  Host.new(self: {kind: "host"}, name: name, kind: kind, on_error: quiet_on_error,
    upstream: C.upstream(link, principal: {kind: "server"}))
end

describe "WebSocket links" do
  it "serves a browser-style client over a real socket, stamped by the authenticator" do
    host = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    host.serve(BOARD) do |_input, principal, scope|
      notes = scope.state("notes", T.array(T.string), [] of JSON::Any)
      Implementation.new("main")
        .state("notes", notes)
        .method("add") { |text, ctx| notes.change(ctx) { |draft| draft << text.not_nil! } }
        .method("who") { principal }
    end
    handler = C.accept_web_sockets(host) do |context|
      context.request.query_params["token"]? == "ok" ? {guest: "web"} : nil
    end
    http, port = listen(handler)
    begin
      client = browser(port, "ok")
      board = client.hold(BOARD)
      seen = [] of JSON::Any
      board.state("notes").subscribe { |value| seen << value }
      board.call("add", "hello")
      board.call("who").should eq j(%({"guest":"web"}))
      eventually { board.state("notes").value == j(%(["hello"])) }
      seen.last.should eq j(%(["hello"]))
      client.close

      impostor = browser(port, "ok", "session:S1", PeerKind::Host)
      error = expect_raises(ChordError) do
        impostor.root(signal: timeout_signal(150.milliseconds)) { |ctx| impostor.hold(BOARD).call("add", "x", ctx) }
      end
      error.code.should eq ErrorCode::Aborted
      impostor.close

      refused = browser(port, "bad")
      denied = refused.hold(BOARD)
      error = expect_raises(ChordError) do
        refused.root(signal: timeout_signal(100.milliseconds)) { |ctx| denied.call("add", "x", ctx) }
      end
      error.code.should eq ErrorCode::Aborted
      refused.close
    ensure
      http.try &.close
    end
  end
end

describe "WebSocket links: packed payloads" do
  it "large snapshots and results reach the client as binary messages; clients may not send them" do
    notes = JSON::Any.new((0...40).map { |i| JSON::Any.new("#{i}:#{"x" * 4000}") })
    host = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    host.serve(BOARD) do |_input, _principal, scope|
      state = scope.state("notes", T.array(T.string), notes)
      Implementation.new("main").state("notes", state).method("add") { nil }.method("who") { notes }
    end
    http, port = listen(C.accept_web_sockets(host) { {guest: "web"} })
    begin
      socket = HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:#{port}/"))
      binary = [] of Bytes
      text = [] of String
      socket.on_binary { |bytes| binary << bytes.dup }
      socket.on_message { |message| text << message }
      spawn { socket.run }
      socket.send(wire("hello", protocol: PROTOCOL_VERSION, name: "raw", kind: "client", codeVersion: 0).to_json)
      socket.send(wire("hold", id: 1, at: "server", token: BOARD.description.json, input: j("{}")).to_json)
      socket.send(wire("call", id: 2, hold: 1, member: "who").to_json)
      eventually { binary.size >= 2 }
      frames = binary.map { |message| JSON.parse(Wire.inflate_message(message)) }
      frames.any? { |frame| frame["t"] == "result" && frame["value"] == notes }.should be_true
      frames.any? { |frame| frame["t"] == "state" && frame["value"] == notes }.should be_true
      text.any? { |message| JSON.parse(message)["t"] == "shape" }.should be_true
      socket.close

      raw = HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:#{port}/"))
      closed = Channel(Nil).new(1)
      raw.on_close { notify(closed) }
      spawn { raw.run; notify(closed) }
      raw.send(Bytes[0, 0, 0, 2, 123, 125])
      select
      when closed.receive
      when timeout(2.seconds)
        fail "the server kept a socket that sent a binary message"
      end
    ensure
      http.try &.close
    end
  end
end
