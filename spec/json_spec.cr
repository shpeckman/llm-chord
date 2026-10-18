# spec/json_spec.cr
require "./spec_helper"

describe LLM::Chord::Json do
  it "deep copies independently of the source" do
    original = JSON.parse(%({"a":[1,2],"b":{"c":"x"}}))
    copy = LLM::Chord::Json.deep_copy(original)
    copy.should eq original
    copy.as_h["a"].as_a << JSON::Any.new(3_i64)
    original["a"].as_a.size.should eq 2
    copy["a"].as_a.size.should eq 3
  end

  it "validates finite numbers" do
    LLM::Chord::Json.valid?(JSON.parse(%({"a":1}))).should be_true
    LLM::Chord::Json.valid?(JSON::Any.new(Float64::INFINITY)).should be_false
    LLM::Chord::Json.valid?(JSON::Any.new(0.0 / 0.0)).should be_false
  end

  it "recognizes containers" do
    LLM::Chord::Json.container?(JSON.parse(%({"a":1}))).should be_true
    LLM::Chord::Json.container?(JSON.parse(%([1,2]))).should be_true
    LLM::Chord::Json.container?(JSON.parse(%(1))).should be_false
    LLM::Chord::Json.container?(JSON.parse(%(null))).should be_false
  end

  it "converts Crystal values to JSON::Any" do
    LLM::Chord::Json.to_any({"a" => 1, "b" => [true, nil]}).should eq JSON.parse(%({"a":1,"b":[true,null]}))
    LLM::Chord::Json.to_any(42).raw.should eq 42_i64
  end
end
