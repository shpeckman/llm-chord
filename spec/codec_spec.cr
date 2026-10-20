# spec/codec_spec.cr
require "./spec_helper"

describe LLM::Chord::Delta::Encoder do
  it "interns paths, omits adjacent paths, and round-trips" do
    encoder = Encoder.new
    decoder = Decoder.new
    first = ops(%([["t",["nested","text"],1],["a",["nested","text"],"x"]]))
    tuples(decoder.decode(encoder.encode(first))).should eq tuples(first)
    second = ops(%([["a",["nested","text"],"y"]]))
    wire = encoder.encode(second)
    JSON::Any.new(wire).should eq j(%([["#",0,["nested","text"]],["a",0,"y"]]))
    tuples(decoder.decode(wire)).should eq tuples(second)
  end

  it "resets path dictionaries on a base" do
    encoder = Encoder.new
    encoder.encode(ops(%([["s",["value"],1]])))
    encoder.encode(ops(%([["s",["value"],2]])))
    JSON::Any.new(encoder.encode(ops(%([["r",{"value":3}]])))).should eq j(%([["r",{"value":3}]]))
    JSON::Any.new(encoder.encode(ops(%([["s",["value"],4]])))).should eq j(%([["s",["value"],4]]))
  end

  it "omits an adjacent repeated path" do
    JSON::Any.new(Encoder.new.encode(ops(%([["s",["value"],1],["s",["value"],2]])))).should eq j(%([["s",["value"],1],["s",2]]))
  end

  it "interns on second use rather than first" do
    encoder = Encoder.new
    JSON::Any.new(encoder.encode(ops(%([["a",["a","deep"],"1"]])))).should eq j(%([["a",["a","deep"],"1"]]))
    JSON::Any.new(encoder.encode(ops(%([["a",["a","deep"],"2"]])))).should eq j(%([["#",0,["a","deep"]],["a",0,"2"]]))
  end

  it "does not collide paths containing null characters" do
    operations = [Op::Set.new(path("a\u0000b"), JSON::Any.new(1_i64)), Op::Set.new(path("a", "b"), JSON::Any.new(2_i64))] of Op
    tuples(Decoder.new.decode(Encoder.new.encode(operations))).should eq tuples(operations)
  end

  it "makes batches after a base self-contained" do
    encoder = Encoder.new
    encoder.encode(ops(%([["a",["a","deep"],"1"]])))
    encoder.encode(ops(%([["a",["a","deep"],"2"]])))
    base = encoder.encode(ops(%([["r",{"a":{"deep":"x"}}]])))
    after = encoder.encode(ops(%([["a",["a","deep"],"3"]])))
    JSON::Any.new(after).should eq j(%([["a",["a","deep"],"3"]]))
    decoder = Decoder.new
    tuples(decoder.decode(base)).should eq j(%([["r",{"a":{"deep":"x"}}]]))
    tuples(decoder.decode(after)).should eq j(%([["a",["a","deep"],"3"]]))
  end

  it "round-trips deterministic mixed operation streams" do
    batches = (0...100).map do |index|
      ops(%([["s",["rows",#{index},"value"],#{index}],["a",["output"],"#{index}"],["p",["tail"],#{index},0,[#{index}]]]))
    end
    encoder = Encoder.new
    decoder = Decoder.new
    batches.each { |batch| tuples(decoder.decode(encoder.encode(batch))).should eq tuples(batch) }
  end

  it "validates and encodes permutations" do
    operations = ops(%([["m",["values"],[2,0,1]],["m",["values"],[1,2,0]]]))
    wire = Encoder.new.encode(operations)
    JSON::Any.new(wire).should eq j(%([["m",["values"],[2,0,1]],["m",[1,2,0]]]))
    wire.each { |op| Delta.assert_valid_wire_op(op) }
    tuples(Decoder.new.decode(wire)).should eq tuples(operations)
  end
end

describe LLM::Chord::Delta::Decoder do
  it "rejects unresolved short forms and unsafe interned paths" do
    expect_raises(PathError) { Decoder.new.decode(j(%([["a","x"]])).as_a) }
    expect_raises(UnsafePathError) { Decoder.new.decode(j(%([["#",0,["__proto__"]],["s",0,true]])).as_a) }
    expect_raises(UnsafePathError) { Decoder.new.decode(j(%([["#",0,["__proto__","w"]],["s",0,true]])).as_a) }
  end

  it "clears ids on a base batch" do
    decoder = Decoder.new
    decoder.decode(j(%([["#",0,["a"]],["a",0,"1"]])).as_a)
    decoder.decode(j(%([["r",{"a":""}]])).as_a)
    expect_raises(PathError) { decoder.decode(j(%([["a",0,"2"]])).as_a) }
  end

  it "keeps path ids across batches" do
    decoder = Decoder.new
    decoder.decode(j(%([["#",3,["deep","path"]],["s",3,1]])).as_a)
    tuples(decoder.decode(j(%([["s",3,2]])).as_a)).should eq j(%([["s",["deep","path"],2]]))
  end

  it "rejects malformed tuples" do
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([["t",["value"],-1]])).as_a) }
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([["a",["value"],1]])).as_a) }
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([["s"]])).as_a) }
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([["m",["v"],[0,0]]])).as_a) }
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([["zz",["v"]]])).as_a) }
    expect_raises(ArgumentError) { Decoder.new.decode(j(%([{"op":"s"}])).as_a) }
    expect_raises(PathError) { Decoder.new.decode(j(%([["s",[],1]])).as_a) }
  end

  it "decodes root splices and permutations with empty paths" do
    tuples(Decoder.new.decode(j(%([["p",[],0,0,[1]],["m",[],[0]]])).as_a)).should eq j(%([["p",[],0,0,[1]],["m",[],[0]]]))
  end
end
