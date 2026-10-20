# conformance/crystal_server.cr
require "http/server"
require "./contracts"

host = LLM::Chord::Host.new(self: {kind: "host"}, name: "server")
host.serve(Conformance::BOARD) do |_input, principal, scope|
  notes = scope.state("notes", Conformance::T.array(Conformance::T.string), [] of JSON::Any)
  LLM::Chord::Implementation.new("main")
    .state("notes", notes)
    .method("add") { |text, ctx| notes.change(ctx) { |draft| draft << text.not_nil! } }
    .method("who") { principal }
end
handler = LLM::Chord.accept_web_sockets(host) do |context|
  context.request.query_params["token"]? == "ok" ? {guest: "web"} : nil
end
server = HTTP::Server.new([handler])
address = server.bind_tcp("127.0.0.1", 0)
STDOUT.puts "listening #{address.port}"
STDOUT.flush
server.listen
