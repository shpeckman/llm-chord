# spec/draft_spec.cr
require "./spec_helper"

private def edit(initial : String, & : Draft -> _) : Prepared
  tracker = Delta.track(j(initial))
  change = tracker.begin_change
  yield change.state
  change.prepare
end

describe LLM::Chord::Delta::Draft do
  it "reads values and typed accessors" do
    edit(%({"s":"x","i":1,"f":1.5,"b":true,"n":null,"a":[1],"o":{"k":1}})) do |draft|
      draft["s"].as_s.should eq "x"
      draft["i"].as_i.should eq 1
      draft["f"].as_f.should eq 1.5
      draft["b"].as_bool.should be_true
      draft["n"].null?.should be_true
      draft["missing"].null?.should be_true
      draft["missing"]?.should be_nil
      draft.string?("s").should eq "x"
      draft.string?("i").should be_nil
      draft.int("i").should eq 1
      draft.float("f").should eq 1.5
      draft.bool("b").should be_true
      draft.array("a").map(&.as_i).should eq [1]
      draft.object("o")["k"].as_i.should eq 1
      draft.size.should eq 7
      draft["a"][0].as_i.should eq 1
      draft["a"][5]?.should be_nil
      expect_raises(IndexError) { draft["a"][5] }
      expect_raises(OverlayError, /not an integer/) { draft.int("s") }
      expect_raises(OverlayError, /missing/) { draft.int("zz") }
      expect_raises(OverlayError, /not an array/) { draft["o"] << 1 }
      expect_raises(OverlayError, /not an object/) { draft["a"]["k"] = 1 }
    end
  end

  it "returns a detached snapshot from value" do
    edit(%({"o":{"k":1}})) do |draft|
      snapshot = draft["o"].value
      snapshot.as_h["k"] = JSON::Any.new(9_i64)
      draft["o"]["k"].as_i.should eq 1
    end.ops.should be_empty
  end

  it "clones property, index, push, unshift, splice, fill, and copy_within placements" do
    external = j(%({"value":1}))
    prepared = edit(%({"left":null,"right":null,"list":[0,0,0]})) do |draft|
      draft["left"] = external
      draft["right"] = external
      draft["left"]["value"] = 2
      draft["list"][0] = external
      draft["list"].push(external)
      draft["list"].unshift(external)
      draft["list"].splice(1, 0, external)
      draft["list"].fill(external, 5)
      draft["list"].copy_within(0, 5)
      draft["list"][0]["value"] = 7
    end
    external.should eq j(%({"value":1}))
    prepared.value.should eq j(%({"left":{"value":2},"right":{"value":1},"list":[{"value":7},{"value":1},{"value":1},0,0,{"value":1}]}))
    same?(prepared.value["left"], prepared.value["right"]).should be_false
    same?(prepared.value["list"][1], prepared.value["list"][2]).should be_false
  end

  it "rejects non-strict JSON placements before changing the draft" do
    prepared = edit(%({"list":[1]})) do |draft|
      expect_raises(ArgumentError) { draft["list"].push(2, Float64::NAN) }
      expect_raises(ArgumentError) { draft["x"] = Float64::INFINITY }
      expect_raises(ArgumentError) { draft["x"] = j("{}").tap { |value| value.as_h["f"] = JSON::Any.new(Float64::NAN) } }
    end
    prepared.ops.should be_empty
  end

  it "deep-clones draft-sourced placements" do
    prepared = edit(%({"a":{"deep":{"v":1}},"b":null})) do |draft|
      draft["b"] = draft["a"]
      draft["b"]["deep"]["v"] = 2
    end
    prepared.value.should eq j(%({"a":{"deep":{"v":1}},"b":{"deep":{"v":2}}}))
  end

  it "rejects array holes and negative indices while allowing replacement and append" do
    prepared = edit(%({"list":[1,2]})) do |draft|
      list = draft["list"]
      expect_raises(OverlayError, /holes/) { list[3] = 9 }
      expect_raises(OverlayError, /indices/) { list[-1] = 9 }
      list[1] = 5
      list[2] = 6
    end
    prepared.value["list"].should eq j("[1,5,6]")
  end

  it "supports deletion, explicit null length growth, shrinking, and default sort" do
    prepared = edit(%({"o":{"a":1,"b":2},"list":[10,9,1,"b","a",true,null]})) do |draft|
      draft["o"].delete("a").try(&.as_i).should eq 1
      draft["o"].delete("zz").should be_nil
      list = draft["list"]
      list.sort!
      list.size = 9
      list.size.should eq 9
      list.size = 8
      expect_raises(OverlayError, /length/) { list.size = -1 }
    end
    prepared.value.should eq j(%({"o":{"b":2},"list":[1,10,9,"a","b",null,true,null]}))
  end

  it "supports all structural mutators and native return values" do
    prepared = edit(%({"list":[1,2,3,4,5]})) do |draft|
      list = draft["list"]
      list.pop.try(&.as_i).should eq 5
      list.shift.try(&.as_i).should eq 1
      list.push(6, 7).should eq 5
      list.unshift(0).should eq 6
      list.splice(1, 2, "x").map(&.as_i).should eq [2, 3]
      list.delete_at(0).as_i.should eq 0
      list.reverse!
      list.splice(-1).map(&.as_s).should eq ["x"]
    end
    prepared.value["list"].should eq j(%([7,6,4]))
  end

  it "returns nil when popping or shifting an empty array without dirtying" do
    prepared = edit(%({"list":[]})) do |draft|
      draft["list"].pop.should be_nil
      draft["list"].shift.should be_nil
      draft["list"].empty?.should be_true
    end
    prepared.ops.should be_empty
  end

  it "tracks held handles after reindex and suppresses detached writes" do
    prepared = edit(%({"list":[{"id":1},{"id":2}]})) do |draft|
      list = draft["list"]
      second = list[1]
      first = list[0]
      list.unshift({"id" => 0})
      second["id"] = 20
      removed = list.shift.not_nil!
      removed["id"] = 99
      list.delete_at(0)
      first["id"] = 100
      second["seen"] = true
    end
    prepared.value["list"].should eq j(%([{"id":20,"seen":true}]))
  end

  it "keeps two handles to the same element consistent" do
    prepared = edit(%({"rows":[{"a":1}]})) do |draft|
      one = draft["rows"][0]
      two = draft["rows"][0]
      one["a"] = 2
      two["b"] = 3
      one["b"].as_i.should eq 3
      two["a"].as_i.should eq 2
    end
    prepared.value.should eq j(%({"rows":[{"a":2,"b":3}]}))
  end

  it "keeps comparator handles attached while sorting with a block" do
    prepared = edit(%({"rows":[{"k":2},{"k":1},{"k":3}]})) do |draft|
      draft["rows"].sort! { |left, right| left["k"].as_i <=> right["k"].as_i }
      draft["rows"][0]["first"] = true
    end
    prepared.value["rows"].should eq j(%([{"k":1,"first":true},{"k":2},{"k":3}]))
  end

  it "supports self-overlapping fill and copy_within by value" do
    prepared = edit(%({"list":[{"v":0},{"v":1},{"v":2},{"v":3},{"v":4}]})) do |draft|
      list = draft["list"]
      list.copy_within(1, 0, 3)
      list[1]["v"] = 10
      list.fill(nil, -1)
    end
    prepared.value["list"].should eq j(%([{"v":0},{"v":10},{"v":1},{"v":2},null]))
  end

  it "emits deletion and supports root arrays" do
    prepared = edit(%([1,2,3])) do |draft|
      draft.delete_at(1)
      draft << 4
    end
    tuples(prepared.ops).should eq j(%([["p",[],1,1,[]],["p",[],2,0,[4]]]))
    prepared.value.should eq j("[1,3,4]")
  end

  it "normalizes restored overrides to no operations" do
    prepared = edit(%({"a":1,"list":[1,2]})) do |draft|
      draft["a"] = 2
      draft["a"] = 1
      draft["list"] << 3
      draft["list"].pop
    end
    prepared.ops.should be_empty
  end

  it "folds edits under reserved keys into an ancestor set" do
    prepared = edit(%({"node":{"x":1}})) do |draft|
      draft["node"]["__proto__"] = 1
    end
    tuples(prepared.ops).should eq j(%([["s",["node"],{"x":1,"__proto__":1}]]))
  end

  it "accepts structs and named tuples as placements" do
    prepared = edit(%({})) do |draft|
      draft["a"] = {name: "n", list: [1, 2]}
      draft["b"] = nil
    end
    prepared.value.should eq j(%({"a":{"name":"n","list":[1,2]},"b":null}))
  end
end
