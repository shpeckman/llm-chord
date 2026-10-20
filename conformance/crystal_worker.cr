# conformance/crystal_worker.cr
require "./contracts"

control = LLM::Chord.child_control
host = LLM::Chord::Host.new(self: {kind: "host"}, name: "w1",
  upstream: LLM::Chord::Upstream.new(control.link, JSON.parse(%({"kind":"server"})), LLM::Chord::LinkOptions.new))
host.serve(Conformance::COUNTER) do |_input, principal, scope|
  count = scope.state("count", Conformance::T.object({n: Conformance::T.number}), {n: 0})
  LLM::Chord::Implementation.new("main")
    .state("count", count)
    .method("add") do |delta, ctx|
      count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i }
      count.value["n"]
    end
    .method("who") { principal }
end
done = Channel(Nil).new
control.on_shutdown do
  host.close
  exit 0
end
control.ready
done.receive
