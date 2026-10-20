# bench/bench.cr
require "../src/llm-chord"
require "benchmark"

include LLM::Chord::Delta

N = 10_000
U = 10_000

Benchmark.bm do |bm|
  bm.report("bulk unshift + prepare") do
    tracker = LLM::Chord::Delta.track(JSON.parse(%({"entries":[]})))
    change = tracker.begin_change
    U.times { |i| change.state["entries"].unshift({"id" => i}) }
    change.prepare
  end

  bm.report("append to long array") do
    tracker = LLM::Chord::Delta.track(JSON.parse(%({"entries":[]})))
    change = tracker.begin_change
    N.times { |i| change.state["entries"] << {"id" => i} }
    tracker.adopt(change.prepare)
  end

  bm.report("hot nested reads") do
    tracker = LLM::Chord::Delta.track(JSON.parse(%({"a":{"b":{"c":{"d":1}}}})))
    change = tracker.begin_change
    total = 0_i64
    N.times { total += change.state["a"]["b"]["c"]["d"].as_i }
    total
  end

  bm.report("small edit in a large revision") do
    rows = Array(JSON::Any).new(N) { |i| JSON.parse(%({"id":#{i},"text":"row"})) }
    tracker = LLM::Chord::Delta.track(JSON::Any.new({"rows" => JSON::Any.new(rows)}))
    100.times do |i|
      change = tracker.begin_change
      change.state["rows"][i]["text"] = "edited"
      tracker.adopt(change.prepare)
    end
  end

  bm.report("immutable replay") do
    base = JSON.parse(%({"n":0}))
    ops = [Op::Set.new(["n"] of Seg, JSON::Any.new(1_i64))] of Op
    N.times { LLM::Chord::Delta.apply_immutable(base, ops) }
  end

  bm.report("structural splice diff") do
    before = JSON::Any.new(Array(JSON::Any).new(1000) { |i| JSON::Any.new(i.to_i64) })
    after = JSON::Any.new((0...1000).reject { |i| i % 3 == 0 }.map { |i| JSON::Any.new(i.to_i64) })
    LLM::Chord::Delta.diff_revisions(before, after)
  end
end
