# conformance/crystal_worker.cr
require "./contracts"

def counter_facet(factor : Int64) : LLM::Chord::Facet
  LLM::Chord.define_facet("counter") do |api|
    api.serve(Conformance::COUNTER) do |_input, principal, scope|
      count = scope.state("count", Conformance::T.object({n: Conformance::T.number}), {n: 0})
      LLM::Chord::Implementation.new("main")
        .state("count", count)
        .method("add") do |delta, ctx|
          count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i * factor }
          count.value["n"]
        end
        .method("who") { principal }
    end
  end
end

control = LLM::Chord.child_control
host = LLM::Chord::Host.new(self: {kind: "host"}, name: "w1",
  upstream: LLM::Chord::Upstream.new(control.link, JSON.parse(%({"kind":"server"})), LLM::Chord::LinkOptions.new),
  loader: ->(names : Array(String)) { names.map { |_name| counter_facet(10) } })
host.install(counter_facet(1))
done = Channel(Nil).new
control.on_shutdown do
  host.close
  exit 0
end
control.ready
done.receive
