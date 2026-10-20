# spec/ops_spec.cr
require "./spec_helper"

describe LLM::Chord::Delta::Op do
  it "accepts decoded operations and rejects wire-only forms" do
    decoded = [
      %(["r",{"value":1}]), %(["s",["value"],1]), %(["d",["value"]]), %(["a",["value"],"x"]),
      %(["t",["value"],2]), %(["p",["value"],0,0,[]]), %(["m",["value"],[0]]),
    ]
    decoded.each { |text| Op.from_tuple(j(text)).to_tuple.should eq j(text) }
    wire_only = [%(["s",1]), %(["d"]), %(["a","x"]), %(["t",2]), %(["p",0,0,[]]), %(["#",0,["value"]]), %(["s",0,1])]
    wire_only.each do |text|
      expect_raises(Exception) { Op.from_tuple(j(text)) }
      Delta.assert_valid_wire_op(j(text))
    end
  end

  it "rejects unknown verbs, malformed tuples, paths, and splice payloads" do
    expect_raises(ArgumentError, /unknown op verb/) { Op.from_tuple(j(%(["ZZZ",["value"],9]))) }
    expect_raises(ArgumentError, /p items/) { Op.from_tuple(j(%(["p",["values"],0,0,"not-an-array"]))) }
    expect_raises(ArgumentError, /path is not an array/) { Op.from_tuple(j(%(["s","value",9]))) }
    expect_raises(ArgumentError, /not a tuple/) { Op.from_tuple(j(%({"op":"s"}))) }
    expect_raises(ArgumentError, /not a tuple/) { Op.from_tuple(j("null")) }
    expect_raises(ArgumentError, /path is empty/) { Op.from_tuple(j(%(["s",[],1]))) }
    expect_raises(ArgumentError, /t shape/) { Op.from_tuple(j(%(["t",["value"],-1]))) }
    expect_raises(ArgumentError, /p index/) { Op.from_tuple(j(%(["p",["value"],1.5,0,[]]))) }
    expect_raises(UnsafePathError) { Op.from_tuple(j(%(["s",["a",-1],1]))) }
    expect_raises(UnsafePathError) { Op.from_tuple(j(%(["s",["a",null],1]))) }
  end

  it "does not recursively inspect operation payloads" do
    Op.from_tuple(j(%(["s",["value"],{"__proto__":{"deep":[1e300]}}]))).verb.should eq 's'
  end

  it "validates in constructors" do
    expect_raises(ArgumentError, /path is empty/) { Op::Set.new([] of Seg, JSON::Any.new(nil)) }
    expect_raises(ArgumentError, /path is empty/) { Op::Delete.new([] of Seg) }
    expect_raises(UnsafePathError) { Op::Append.new(path("constructor"), "x") }
    expect_raises(ArgumentError, /p remove/) { Op::Splice.new(Delta::Path.new, 0, -1, [] of JSON::Any) }
    expect_raises(ArgumentError, /bijection/) { Op::Move.new(Delta::Path.new, [0, 2]) }
    Op::Splice.new(Delta::Path.new, 0, 0, [] of JSON::Any).path.should be_empty
  end

  it "classifies replacements and base batches" do
    Op::Replace.new(j("{}")).replace?.should be_true
    Op::Delete.new(path("a")).replace?.should be_false
    Delta.base?(ops(%([["r",{}],["s",["a"],1]]))).should be_true
    Delta.base?(ops(%([["s",["a"],1]]))).should be_false
    Delta.base?([] of Op).should be_false
    Delta.base?(j(%([["r",{}]])).as_a).should be_true
    Delta.base?(j(%([["#",0,["a"]]])).as_a).should be_false
  end

  it "formats errors like upstream" do
    UnsafePathError.new("__proto__").message.should eq "unsafe path segment: __proto__"
    PathError.new(path("a", 1)).message.should eq %(unresolvable path: ["a",1])
    PathError.new(3_i64).message.should eq "unresolvable path: 3"
  end
end
