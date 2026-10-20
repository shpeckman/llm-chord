# spec/cell_spec.cr
require "./spec_helper"
include LLM::Chord

describe LLM::Chord::Cell do
  it "derives a value from a state" do
    state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
    cell = LLM::Chord::Cell.from(state) { |value| JSON::Any.new(value["n"].as_i * 2) }
    cell.value.as_i.should eq 0_i64
    state.change { |draft| draft["n"] = 5 }
    cell.value.as_i.should eq 10_i64
  end

  it "notifies subscribers on change and not on a no-op" do
    state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
    cell = LLM::Chord::Cell.from(state) { |value| JSON::Any.new(value["n"].as_i) }
    seen = [] of Int64
    cell.subscribe { |value| seen << value.as_i }
    seen.should eq [0_i64]
    state.change { |draft| draft["n"] = 1 }
    state.change { |draft| draft["n"] = 1 }
    seen.should eq [0_i64, 1_i64]
  end

  it "stops notifying after unsubscribe" do
    state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
    cell = LLM::Chord::Cell.from(state) { |value| value }
    seen = [] of Int64
    unsub = cell.subscribe { |value| seen << value["n"].as_i }
    unsub.call
    state.change { |draft| draft["n"] = 1 }
    seen.should eq [0_i64]
  end
end
