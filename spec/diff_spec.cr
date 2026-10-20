# spec/diff_spec.cr
require "./spec_helper"
include LLM::Chord::Delta

private def round_trip(before : String, after : String)
  b = JSON.parse(before)
  a = JSON.parse(after)
  ops = diff_revisions(b, a)
  apply_immutable(b, ops).should eq a
end

describe LLM::Chord::Delta do
  describe ".diff_revisions" do
    it "produces no ops for equal values" do
      diff_revisions(JSON.parse(%({"a":1})), JSON.parse(%({"a":1}))).should be_empty
    end

    it "round-trips a string append" do
      round_trip(%({"output":"a"}), %({"output":"ab"}))
    end

    it "round-trips a string truncate" do
      round_trip(%({"output":"hello"}), %({"output":"llo"}))
    end

    it "round-trips a string replace" do
      round_trip(%({"output":"hello"}), %({"output":"world"}))
    end

    it "round-trips an object property set" do
      round_trip(%({"a":1,"b":2}), %({"a":1,"b":3}))
    end

    it "round-trips an object property add and delete" do
      round_trip(%({"a":1,"b":2}), %({"a":1,"c":3}))
    end

    it "round-trips an array splice" do
      round_trip(%({"arr":[0,1,2,3]}), %({"arr":[0,"x","y",3]}))
    end

    it "round-trips an array reorder" do
      round_trip(%({"arr":[1,2,3]}), %({"arr":[3,1,2]}))
    end

    it "round-trips a whole-root replacement" do
      round_trip(%({"a":1}), %([1,2,3]))
    end

    it "round-trips nested edits" do
      round_trip(%({"a":{"b":[1,2],"c":"x"}}), %({"a":{"b":[1,9,2],"c":"xy"}}))
    end

    it "folds reserved keys into a whole-object set" do
      ops = diff_revisions(JSON.parse(%({"safe":1})), JSON.parse(%({"safe":1,"__proto__":true})))
      ops.size.should eq 1
      ops.first.should be_a(Op::Replace)
    end

    it "emits a string append for a pure suffix" do
      ops = diff_revisions(JSON.parse(%({"s":"abc"})), JSON.parse(%({"s":"abcdef"})))
      ops.size.should eq 1
      ops.first.should be_a(Op::Append)
      ops.first.as(Op::Append).text.should eq "def"
    end

    it "round-trips a truncate of an astral prefix" do
      round_trip(%({"s":"😀x"}), %({"s":"x"}))
    end

    it "round-trips an append after an astral character" do
      round_trip(%({"s":"a😀"}), %({"s":"a😀b"}))
    end
  end
end
