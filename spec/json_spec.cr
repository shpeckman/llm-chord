# spec/json_spec.cr
require "./spec_helper"

describe LLM::Chord::Json do
  it "deep-copies containers into independent trees" do
    original = j(%({"a":[1,{"b":2}]}))
    copy = Json.deep_copy(original)
    copy.should eq original
    same?(copy["a"], original["a"]).should be_false
    same?(copy["a"][1], original["a"][1]).should be_false
  end

  it "copies strict JSON and rejects non-finite numbers" do
    copy = Json.copy_json(j(%({"a":[1.5]})))
    copy.should eq j(%({"a":[1.5]}))
    bad = j(%({"a":[]}))
    bad["a"].as_a << JSON::Any.new(Float64::NAN)
    expect_raises(ArgumentError, /non-finite/) { Json.copy_json(bad) }
  end

  it "distinguishes identity from structural equality" do
    left = j(%({"a":1}))
    right = j(%({"a":1}))
    Json.identical?(left, left).should be_true
    Json.identical?(left, right).should be_false
    Json.equal?(left, right).should be_true
    Json.identical?(JSON::Any.new("x"), JSON::Any.new("x")).should be_true
    Json.identical?(JSON::Any.new(1_i64), JSON::Any.new(1.0)).should be_true
  end

  it "compares objects regardless of key order" do
    Json.equal?(j(%({"a":1,"b":[1,{"c":2}]})), j(%({"b":[1,{"c":2}],"a":1}))).should be_true
    Json.equal?(j(%({"a":1})), j(%({"a":1,"b":2}))).should be_false
    Json.equal?(j("[1,2]"), j("[2,1]")).should be_false
    Json.equal?(j("{}"), j("[]")).should be_false
  end

  it "reports container kinds" do
    Json.container?(j("{}")).should be_true
    Json.container?(j("[]")).should be_true
    Json.container?(j("1")).should be_false
  end

  it "converts Crystal values to strict JSON" do
    Json.to_any({"a" => [1, 2], "b" => nil}).should eq j(%({"a":[1,2],"b":null}))
    expect_raises(ArgumentError) { Json.to_any(Float64::NAN) }
  end

  it "round-trips serializable structs" do
    value = Json.from_struct({name: "x", count: 2})
    value.should eq j(%({"name":"x","count":2}))
    Json.to_struct(Hash(String, Int32), j(%({"a":1}))).should eq({"a" => 1})
  end

  it "validates strict JSON" do
    Json.valid?(j(%({"a":[1,"x",null,true]}))).should be_true
    invalid = j("[]")
    invalid.as_a << JSON::Any.new(Float64::INFINITY)
    Json.valid?(invalid).should be_false
    Json.strict?(invalid).should be_false
    expect_raises(ArgumentError) { Json.validate!(invalid) }
  end

  it "renders JavaScript string coercions for default sorting" do
    Json.js_string(j("null")).should eq "null"
    Json.js_string(j("2.0")).should eq "2"
    Json.js_string(j("1.5")).should eq "1.5"
    Json.js_string(j(%([1,null,"a",[2,3]]))).should eq "1,,a,2,3"
    Json.js_string(j("{}")).should eq "[object Object]"
  end
end
