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

    it "round-trips a path id through the decoder" do
      ops = [
        Op::Set.new(path("a"), JSON::Any.new(1_i64)),
        Op::Set.new(path("b"), JSON::Any.new(2_i64)),
        Op::Set.new(path("a"), JSON::Any.new(3_i64)),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"a":0,"b":0}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "round-trips a short-form delete" do
      ops = [
        Op::Set.new(path("a"), JSON::Any.new("x")),
        Op::Delete.new(path("a")),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"a":"old"}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "round-trips a short-form truncate" do
      ops = [
        Op::Set.new(path("s"), JSON::Any.new("hello")),
        Op::Truncate.new(path("s"), 2),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"s":""}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "round-trips a short-form splice" do
      items = [JSON::Any.new("a"), JSON::Any.new("b")]
      ops = [
        Op::Splice.new(path("arr"), 0, 0, items),
        Op::Splice.new(path("arr"), 0, 1, [] of JSON::Any),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"arr":[]}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "round-trips a short-form move" do
      ops = [
        Op::Move.new(path("arr"), [1, 0]),
        Op::Move.new(path("arr"), [0, 1]),
      ]
      wire = Encoder.new.encode(ops)
      decoded = Decoder.new.decode(wire)
      base = JSON.parse(%({"arr":[1,2]}))
      apply_immutable(base, decoded).should eq apply_immutable(base, ops)
    end

    it "re-emits a full path after a mid-batch replacement" do
      ops = [
        Op::Set.new(path("a"), JSON::Any.new(1_i64)),
        Op::Replace.new(JSON.parse(%({"n":9}))),
        Op::Set.new(path("a"), JSON::Any.new(2_i64)),
      ]
      wire = Encoder.new.encode(ops)
      wire.map(&.as_a.first.as_s).should eq ["s", "r", "s"]
      wire[2].as_a[1].should eq JSON.parse(%(["a"]))
    end
  end

  describe "Decoder" do
    it "rejects a non-array op" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON::Any.new(1_i64)] of JSON::Any) }
    end

    it "rejects an empty tuple" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%([]))] of JSON::Any) }
    end

    it "rejects a malformed path-id entry" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["#",0]))] of JSON::Any) }
    end

    it "rejects a replacement with wrong arity" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["r",1,2]))] of JSON::Any) }
    end

    it "rejects an unknown verb" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["x",["a"],1]))] of JSON::Any) }
    end

    it "rejects a non-array path" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["s","x",1]))] of JSON::Any) }
    end

    it "rejects a bad path segment" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["s",[true],1]))] of JSON::Any) }
    end

    it "rejects a non-integer arity argument" do
      expect_raises(ArgumentError) { Decoder.new.decode([JSON.parse(%(["t",["a"],"x"]))] of JSON::Any) }
    end

    it "rejects an unknown path id" do
      expect_raises(PathError) { Decoder.new.decode([JSON.parse(%(["s",7,1]))] of JSON::Any) }
    end

    it "rejects a short form with no previous path" do
      expect_raises(PathError) { Decoder.new.decode([JSON.parse(%(["d"]))] of JSON::Any) }
    end

    it "rejects an empty path for a leaf op" do
      expect_raises(PathError) { Decoder.new.decode([JSON.parse(%(["s",[],1]))] of JSON::Any) }
    end
  end
end
