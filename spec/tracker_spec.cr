# spec/tracker_spec.cr
require "./spec_helper"
include LLM::Chord::Delta

describe LLM::Chord::Delta do
  describe ".track" do
    it "starts at revision zero with the initial value" do
      initial = JSON.parse(%({"n":0}))
      tracker = track(initial)
      tracker.value.should eq initial
      tracker.revision.should eq 0
    end

    it "adopts a mutated change" do
      tracker = track(JSON.parse(%({"n":0})))
      change = tracker.begin_change
      change.state.as_h["n"] = JSON::Any.new(1_i64)
      prepared = change.prepare
      prepared.ops.should_not be_empty
      tracker.adopt(prepared)
      tracker.value.should eq JSON.parse(%({"n":1}))
      tracker.revision.should eq 1
    end

    it "yields empty ops for a no-op change" do
      tracker = track(JSON.parse(%({"n":0})))
      change = tracker.begin_change
      prepared = change.prepare
      prepared.ops.should be_empty
      prepared.value.should eq tracker.value
      tracker.adopt(prepared)
      tracker.revision.should eq 1
    end

    it "rejects a stale prepared change after a competing adopt" do
      tracker = track(JSON.parse(%({"n":0})))
      first = tracker.begin_change
      first.state.as_h["n"] = JSON::Any.new(1_i64)
      p1 = first.prepare
      second = tracker.begin_change
      second.state.as_h["n"] = JSON::Any.new(2_i64)
      p2 = second.prepare
      tracker.adopt(p1)
      expect_raises(Exception) { tracker.adopt(p2) }
    end

    it "rejects an aborted prepared change" do
      tracker = track(JSON.parse(%({"n":0})))
      change = tracker.begin_change
      change.state.as_h["n"] = JSON::Any.new(1_i64)
      prepared = change.prepare
      prepared.abort
      expect_raises(Exception) { tracker.adopt(prepared) }
    end

    it "supports whole-root replacement" do
      tracker = track(JSON.parse(%({"n":0})))
      prepared = tracker.prepare_replace(JSON.parse(%({"n":1})))
      tracker.adopt(prepared)
      tracker.value.should eq JSON.parse(%({"n":1}))
    end

    it "keeps the current root for a no-op replacement" do
      tracker = track(JSON.parse(%({"n":0})))
      prepared = tracker.prepare_replace(JSON.parse(%({"n":0})))
      prepared.ops.should be_empty
    end

    it "raises when state is read after settle" do
      tracker = track(JSON.parse(%({"n":0})))
      change = tracker.begin_change
      change.prepare
      expect_raises(Exception) { change.state }
    end
  end
end
