# spec/apply_spec.cr
require "./spec_helper"
include LLM::Chord::Delta

describe LLM::Chord::Delta do
  describe ".apply" do
    it "sets an object property" do
      base = JSON.parse(%({"a":0}))
      apply(base, [Op::Set.new(path("a"), JSON::Any.new(1_i64))]).should eq JSON.parse(%({"a":1}))
    end

    it "sets an array element and appends at the end" do
      base = JSON.parse(%([0,1]))
      apply(base, [Op::Set.new(path(1), JSON::Any.new(9_i64))]).should eq JSON.parse(%([0,9]))
      apply(base, [Op::Set.new(path(2), JSON::Any.new(2_i64))]).should eq JSON.parse(%([0,9,2]))
    end

    it "deletes an object property" do
      base = JSON.parse(%({"a":1,"b":2}))
      apply(base, [Op::Delete.new(path("b"))]).should eq JSON.parse(%({"a":1}))
    end

    it "deletes an array element" do
      base = JSON.parse(%([0,1,2]))
      apply(base, [Op::Delete.new(path(1))]).should eq JSON.parse(%([0,2]))
    end

    it "appends to a string" do
      base = JSON.parse(%({"s":"hi"}))
      apply(base, [Op::Append.new(path("s"), "!")]).should eq JSON.parse(%({"s":"hi!"}))
    end

    it "truncates a string from the front" do
      base = JSON.parse(%({"s":"hello"}))
      apply(base, [Op::Truncate.new(path("s"), 2)]).should eq JSON.parse(%({"s":"llo"}))
    end

    it "splices an array" do
      base = JSON.parse(%({"arr":[0,1,2,3]}))
      items = [JSON::Any.new("x"), JSON::Any.new("y")]
      apply(base, [Op::Splice.new(path("arr"), 1, 2, items)]).should eq JSON.parse(%({"arr":[0,"x","y",3]}))
    end

    it "moves array elements" do
      base = JSON.parse(%([0,1]))
      apply(base, [Op::Move.new([] of Seg, [1, 0])]).should eq JSON.parse(%([1,0]))
    end

    it "replaces the root" do
      base = JSON.parse(%({"a":0}))
      apply(base, [Op::Replace.new(JSON.parse(%({"b":1})))]).should eq JSON.parse(%({"b":1}))
    end

    it "rejects reserved path segments" do
      base = JSON.parse(%({}))
      expect_raises(UnsafePathError) { apply(base, [Op::Set.new(path("__proto__"), JSON::Any.new(true))]) }
    end

    it "rejects an out-of-range array index" do
      base = JSON.parse(%([0,1]))
      expect_raises(UnsafePathError) { apply(base, [Op::Set.new(path(5), JSON::Any.new(1_i64))]) }
    end

    it "raises on an unresolvable path" do
      base = JSON.parse(%({"a":1}))
      expect_raises(PathError) { apply(base, [Op::Set.new(path("missing", "deep"), JSON::Any.new(1_i64))]) }
    end

    it "mutates the target in place" do
      base = JSON.parse(%({"a":0}))
      result = apply(base, [Op::Set.new(path("a"), JSON::Any.new(1_i64))])
      result.should eq JSON.parse(%({"a":1}))
      base.should eq JSON.parse(%({"a":1}))
    end

    it "truncates an entire string to empty" do
      base = JSON.parse(%({"s":"ab"}))
      apply(base, [Op::Truncate.new(path("s"), 2)]).should eq JSON.parse(%({"s":""}))
    end

    it "truncates past the end to empty" do
      base = JSON.parse(%({"s":"ab"}))
      apply(base, [Op::Truncate.new(path("s"), 5)]).should eq JSON.parse(%({"s":""}))
    end

    it "truncates by UTF-16 code units" do
      base = JSON.parse(%({"s":"😀x"}))
      apply(base, [Op::Truncate.new(path("s"), 2)]).should eq JSON.parse(%({"s":"x"}))
    end

    it "rejects a move with a mismatched permutation" do
      base = JSON.parse(%([0,1,2]))
      expect_raises(PathError) { apply(base, [Op::Move.new([] of Seg, [1, 0])]) }
    end

    it "rejects a splice on a non-array" do
      base = JSON.parse(%({"a":1}))
      expect_raises(PathError) { apply(base, [Op::Splice.new(path("a"), 0, 0, [] of JSON::Any)]) }
    end

    it "rejects a move on a non-array" do
      base = JSON.parse(%({"a":1}))
      expect_raises(PathError) { apply(base, [Op::Move.new(path("a"), [0])]) }
    end
  end

  describe ".apply_immutable" do
    it "leaves the target unmodified" do
      base = JSON.parse(%({"a":0}))
      result = apply_immutable(base, [Op::Set.new(path("a"), JSON::Any.new(1_i64))])
      result.should eq JSON.parse(%({"a":1}))
      base.should eq JSON.parse(%({"a":0}))
    end

    it "keeps a nested target independent of the result" do
      base = JSON.parse(%({"a":{"b":[1]}}))
      result = apply_immutable(base, [Op::Set.new(path("a", "b", 0), JSON::Any.new(9_i64))])
      result["a"]["b"].as_a << JSON::Any.new(2_i64)
      base["a"]["b"].as_a.size.should eq 1
      base["a"]["b"].as_a[0].raw.should eq 1_i64
    end

    it "does not alias a replacement payload" do
      payload = JSON.parse(%({"n":0}))
      result = apply_immutable(JSON.parse(%({"old":true})), [Op::Replace.new(payload)])
      payload.as_h["n"] = JSON::Any.new(1_i64)
      result["n"].as_i.should eq 0_i64
    end

    it "does not alias a set payload" do
      payload = JSON.parse(%({"n":0}))
      result = apply_immutable(JSON.parse(%({"a":0})), [Op::Set.new(path("a"), payload)])
      payload.as_h["n"] = JSON::Any.new(1_i64)
      result["a"]["n"].as_i.should eq 0_i64
    end

    it "does not alias a splice payload" do
      items = [JSON.parse(%({"n":0}))]
      result = apply_immutable(JSON.parse(%({"arr":[]})), [Op::Splice.new(path("arr"), 0, 0, items)])
      items[0].as_h["n"] = JSON::Any.new(1_i64)
      result["arr"].as_a[0]["n"].as_i.should eq 0_i64
    end
  end

  describe ".apply_immutable_batches" do
    it "applies several batches in order" do
      base = JSON.parse(%({"a":0}))
      b1 = [Op::Set.new(path("a"), JSON::Any.new(1_i64))]
      b2 = [Op::Set.new(path("a"), JSON::Any.new(2_i64))]
      apply_immutable_batches(base, [b1, b2]).should eq JSON.parse(%({"a":2}))
    end
  end
end
