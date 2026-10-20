# spec/apply_spec.cr
require "./spec_helper"

describe "LLM::Chord::Delta.apply" do
  it "applies mutable and immutable operations" do
    operations = ops(%([["a",["text"],"b"],["p",["values"],1,1,[3,4]],["s",["nested","value"],2]]))
    base = j(%({"text":"a","values":[1,2],"nested":{"value":1},"stable":{"value":9}}))
    immutable = Delta.apply_immutable(base, operations)
    immutable.should eq j(%({"text":"ab","values":[1,3,4],"nested":{"value":2},"stable":{"value":9}}))
    base.should eq j(%({"text":"a","values":[1,2],"nested":{"value":1},"stable":{"value":9}}))
    same?(immutable["stable"], base["stable"]).should be_true
    Delta.apply(Json.deep_copy(base), operations).should eq immutable
  end

  it "supports root replacement, root splice, and permutations" do
    base = ops(%([["r",[1,2,3]]]))
    Delta.base?(base).should be_true
    value = Delta.apply(JSON::Any.new(nil), base)
    value = Delta.apply(value, ops(%([["p",[],1,1,[4]]])))
    value = Delta.apply(value, ops(%([["m",[],[2,0,1]]])))
    value.should eq j("[3,1,4]")
  end

  it "rejects unsafe and malformed paths" do
    expect_raises(UnsafePathError) { Delta.apply(j("{}"), ops(%([["s",["constructor","prototype","x"],true]]))) }
    expect_raises(UnsafePathError) { Delta.apply(j(%({"values":[1]})), ops(%([["s",["values",3],2]]))) }
    expect_raises(PathError) { Delta.apply(j(%({"value":1})), ops(%([["a",["value"],"x"]]))) }
    expect_raises(ArgumentError) { Op.from_tuple(j(%(["s","value",1]))) }
    expect_raises(ArgumentError, /bijection/) { Op.from_tuple(j(%(["m",[],[0,0]]))) }
  end

  it "adopts a mutable replacement payload rather than copying it" do
    batch = ops(%([["r",{"value":0}]]))
    first = Delta.apply(JSON::Any.new(nil), batch)
    second = Delta.apply(JSON::Any.new(nil), batch)
    first.as_h["value"] = JSON::Any.new(1_i64)
    second["value"].should eq JSON::Any.new(1_i64)
  end

  it "allows reserved names inside values" do
    result = Delta.apply(j("{}"), [Op::Set.new(path("value"), j(%({"__proto__":{"z":1}})))] of Op)
    result["value"].as_h.has_key?("__proto__").should be_true
  end

  it "writes an existing index and appends exactly one past the end" do
    Delta.apply(j(%({"values":[1,2,3]})), ops(%([["s",["values",1],9]]))).should eq j(%({"values":[1,9,3]}))
    Delta.apply(j(%({"values":[1,2,3]})), ops(%([["s",["values",3],9]]))).should eq j(%({"values":[1,2,3,9]}))
  end

  it "rejects gaps, huge indices, and string-spelled indices" do
    expect_raises(UnsafePathError) { Delta.apply(j(%({"values":[1,2,3]})), ops(%([["s",["values",5],9]]))) }
    expect_raises(UnsafePathError) { Delta.apply(j(%({"values":[]})), ops(%([["s",["values",4294967290],1]]))) }
    expect_raises(UnsafePathError) { Delta.apply(j(%({"values":[1]})), ops(%([["s",["values","0"],9]]))) }
    expect_raises(UnsafePathError) { Delta.apply(j(%({"values":["a"]})), ops(%([["a",["values","0"],"b"]]))) }
  end

  it "allows explicit growth values and rejects deletion past the end" do
    Delta.apply(j(%({"values":[1]})), ops(%([["p",["values"],1,0,[null,null,9]]]))).should eq j(%({"values":[1,null,null,9]}))
    expect_raises(PathError) { Delta.apply(j(%({"values":[1]})), ops(%([["d",["values",1]]]))) }
  end

  it "applies large splice payloads" do
    items = Array(JSON::Any).new(300_000) { JSON::Any.new(nil) }
    result = Delta.apply(j(%({"values":[]})), [Op::Splice.new(path("values"), 0, 0, items)] of Op)
    result["values"].as_a.size.should eq 300_000
  end

  it "rejects invalid append and truncation operations" do
    expect_raises(PathError) { Delta.apply(j(%({"value":1})), ops(%([["a",["missing"],"x"]]))) }
    expect_raises(PathError) { Delta.apply(j(%({"value":1})), ops(%([["a",["value"],"x"]]))) }
    expect_raises(ArgumentError) { Op::Truncate.new(path("value"), -1) }
  end

  it "clamps splice removal and insertion past the end" do
    Delta.apply(j(%({"values":[1,2]})), ops(%([["p",["values"],0,1e9,[]]]))).should eq j(%({"values":[]}))
    Delta.apply(j(%({"values":[1,2]})), ops(%([["p",["values"],9,0,[3]]]))).should eq j(%({"values":[1,2,3]}))
  end

  it "truncates strings by UTF-16 code units" do
    Delta.apply(j(%({"text":"😀ab"})), ops(%([["t",["text"],2]]))).should eq j(%({"text":"ab"}))
  end

  it "coerces numeric segments to keys on objects" do
    Delta.apply(j(%({"items":{"0":"a"}})), ops(%([["a",["items",0],"b"]]))).should eq j(%({"items":{"0":"ab"}}))
  end

  it "rejects permutations that do not match the array length" do
    expect_raises(PathError) { Delta.apply(j("[1,2,3]"), ops(%([["m",[],[1,0]]]))) }
  end
end

describe "LLM::Chord::Delta.apply_immutable" do
  it "does not mutate a replacement payload targeted by a later operation" do
    replacement = j(%({"nested":{"value":1}}))
    next_value = Delta.apply_immutable(JSON::Any.new(nil), [Op::Replace.new(replacement), Op::Set.new(path("nested", "value"), JSON::Any.new(2_i64))] of Op)
    replacement["nested"]["value"].should eq JSON::Any.new(1_i64)
    next_value["nested"]["value"].should eq JSON::Any.new(2_i64)
  end

  it "copies each touched container once while preserving input and payload ownership" do
    base = j(%({"a":{"b":{"c":1,"d":2}},"untouched":{"x":1},"list":[{"v":1},{"v":2}]}))
    snapshot = Json.deep_copy(base)
    payload = j(%({"fresh":true}))
    operations = [
      Op::Set.new(path("a", "b", "c"), JSON::Any.new(3_i64)),
      Op::Set.new(path("a", "b", "d"), JSON::Any.new(4_i64)),
      Op::Set.new(path("a", "payload"), payload),
      Op::Set.new(path("list", 1, "v"), JSON::Any.new(9_i64)),
    ] of Op
    result = Delta.apply_immutable(base, operations)
    base.should eq snapshot
    result.should eq j(%({"a":{"b":{"c":3,"d":4},"payload":{"fresh":true}},"untouched":{"x":1},"list":[{"v":1},{"v":9}]}))
    same?(result["untouched"], base["untouched"]).should be_true
    same?(result["list"][0], base["list"][0]).should be_true
    same?(result["a"]["payload"], payload).should be_true
    same?(result["a"], base["a"]).should be_false
  end

  it "protects root replacement payloads before later object and array edits" do
    payload = j(%({"list":[1,2],"object":{"k":1}}))
    result = Delta.apply_immutable(j("{}"), [
      Op::Replace.new(payload),
      Op::Splice.new(path("list"), 0, 1, [] of JSON::Any),
      Op::Set.new(path("object", "k"), JSON::Any.new(2_i64)),
    ] of Op)
    payload.should eq j(%({"list":[1,2],"object":{"k":1}}))
    result.should eq j(%({"list":[2],"object":{"k":2}}))
  end

  it "shares one private copy-on-write scope across batch partitions" do
    base = j(%({"values":[1],"text":"a"}))
    batches = [
      ops(%([["p",["values"],1,0,[2]]])),
      ops(%([["p",["values"],2,0,[3]],["a",["text"],"b"]])),
      ops(%([["s",["values",0],0]])),
    ]
    result = Delta.apply_immutable_batches(base, batches)
    result.should eq j(%({"values":[0,2,3],"text":"ab"}))
    base.should eq j(%({"values":[1],"text":"a"}))
  end

  it "allows one immutable batch to fan out without mutating shared payloads" do
    base = j(%({"rows":[]}))
    batch = ops(%([["p",["rows"],0,0,[{"id":1}]],["s",["rows",0,"id"],2]]))
    first = Delta.apply_immutable(base, batch)
    second = Delta.apply_immutable(base, batch)
    first.should eq j(%({"rows":[{"id":2}]}))
    second.should eq j(%({"rows":[{"id":2}]}))
    batch[0].as(Op::Splice).items[0].should eq j(%({"id":1}))
  end

  it "appends to an array not yet copied in one copy, sharing everything else" do
    base = j(%({"log":{"entries":[1,2]},"other":{"x":1}}))
    result = Delta.apply_immutable(base, ops(%([["p",["log","entries"],2,0,[3]]])))
    result.should eq j(%({"log":{"entries":[1,2,3]},"other":{"x":1}}))
    base["log"]["entries"].should eq j("[1,2]")
    same?(result["other"], base["other"]).should be_true
  end

  it "rejects unresolvable paths" do
    expect_raises(PathError) { Delta.apply_immutable(j(%({"a":1})), ops(%([["s",["a","b"],1]]))) }
    expect_raises(PathError) { Delta.apply_immutable(j(%({"a":1})), ops(%([["s",["missing","b"],1]]))) }
  end

  it "handles tracker-produced batches across revision boundaries" do
    tracker = Delta.track(j(%({"rows":[],"text":""})))
    replica = tracker.value
    batches = [] of Array(Op)
    5.times do |index|
      change = tracker.begin_change
      change.state["rows"] << {"id" => index}
      change.state["text"] = change.state["text"].as_s + index.to_s
      prepared = change.prepare
      tracker.adopt(prepared)
      batches << prepared.ops
      replica = Delta.apply_immutable(replica, prepared.ops)
    end
    replica.should eq tracker.value
    Delta.apply_immutable_batches(j(%({"rows":[],"text":""})), batches).should eq tracker.value
  end
end
