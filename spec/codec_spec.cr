# spec/codec_spec.cr
require "./spec_helper"
include LLM::Chord::Delta

describe LLM::Chord::Delta::Encoder do
  describe "with Decoder" do
    it "round-trips a batch through apply" do
      ops = [
        Op::Set.new(path("a"), JSON::Any.new("x")),
        Op::Append.new(path("a"), "y"),
        Op::Set.new(path("b"), JSON::Any.new(1_i64)),
        Op::Set.new(path("a"), JSON::Any.new("z")),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"a":"","b":0}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "round-trips a batch beginning with a replacement" do
      ops = [
        Op::Replace.new(JSON.parse(%({"n":1}))),
        Op::Set.new(path("n"), JSON::Any.new(2_i64)),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"old":true}))
      apply_immutable(base, decoded).should eq JSON.parse(%({"n":2}))
    end

    it "round-trips an empty batch" do
      Decoder.new.decode(Encoder.new.encode([] of Op)).should be_empty
    end

    it "emits a path id on second use" do
      ops = [
        Op::Set.new(path("a"), JSON::Any.new(1_i64)),
        Op::Set.new(path("b"), JSON::Any.new(2_i64)),
        Op::Set.new(path("a"), JSON::Any.new(3_i64)),
      ]
      wire = Encoder.new.encode(ops)
      wire.map(&.as_a.first.as_s).should eq ["s", "s", "#", "s"]
    end
  end
end
