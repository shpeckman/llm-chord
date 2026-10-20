# spec/draft_spec.cr
require "./spec_helper"
include LLM::Chord::Delta

describe LLM::Chord::Delta::Draft do
  it "sets object properties with auto-conversion" do
    tracker = track(JSON.parse(%({"n":0,"s":""})))
    change = tracker.begin_change
    change.state["n"] = 1
    change.state["s"] = "hi"
    tracker.adopt(change.prepare)
    tracker.value.should eq JSON.parse(%({"n":1,"s":"hi"}))
  end

  it "appends to arrays" do
    tracker = track(JSON.parse(%({"items":[]})))
    change = tracker.begin_change
    change.state["items"] << {"id" => 1}
    change.state["items"] << {"id" => 2}
    tracker.adopt(change.prepare)
    tracker.value.should eq JSON.parse(%({"items":[{"id":1},{"id":2}]}))
  end

  it "navigates nested containers" do
    tracker = track(JSON.parse(%({"a":{"b":0}})))
    change = tracker.begin_change
    change.state["a"]["b"] = 9
    tracker.adopt(change.prepare)
    tracker.value.should eq JSON.parse(%({"a":{"b":9}}))
  end

  it "reads typed values" do
    tracker = track(JSON.parse(%({"n":5})))
    change = tracker.begin_change
    change.state["n"].as_i.should eq 5_i64
  end

  it "reports missing keys as nil" do
    tracker = track(JSON.parse(%({})))
    change = tracker.begin_change
    change.state["missing"].null?.should be_true
  end

  it "indexes into arrays" do
    tracker = track(JSON.parse(%({"arr":[10,20]})))
    change = tracker.begin_change
    change.state["arr"][0].as_i.should eq 10_i64
    change.state["arr"][1].as_i.should eq 20_i64
  end

  it "reports present and missing keys via []?" do
    tracker = track(JSON.parse(%({"a":1})))
    change = tracker.begin_change
    change.state["a"]?.should_not be_nil
    change.state["missing"]?.should be_nil
  end

  it "reads each scalar type" do
    tracker = track(JSON.parse(%({"s":"hi","f":1.5,"b":true,"arr":[1],"obj":{"k":1},"n":null})))
    change = tracker.begin_change
    change.state["s"].as_s.should eq "hi"
    change.state["f"].as_f.should eq 1.5
    change.state["b"].as_bool.should be_true
    change.state["arr"].as_a.should eq [JSON::Any.new(1_i64)]
    change.state["obj"].value.should eq JSON.parse(%({"k":1}))
    change.state["n"].null?.should be_true
  end

  it "rejects key access on a non-object" do
    tracker = track(JSON.parse(%(42)))
    change = tracker.begin_change
    expect_raises(Exception) { change.state["x"] }
  end

  it "rejects index access on a non-array" do
    tracker = track(JSON.parse(%({"a":1})))
    change = tracker.begin_change
    expect_raises(Exception) { change.state[0] }
  end

  it "rejects append on a non-array" do
    tracker = track(JSON.parse(%({"a":1})))
    change = tracker.begin_change
    expect_raises(Exception) { change.state << 1 }
  end

  it "rejects key assignment on a non-object" do
    tracker = track(JSON.parse(%(5)))
    change = tracker.begin_change
    expect_raises(Exception) { change.state["a"] = 1 }
  end

  it "rejects index assignment on a non-array" do
    tracker = track(JSON.parse(%({"a":1})))
    change = tracker.begin_change
    expect_raises(Exception) { change.state[0] = 1 }
  end

  it "deletes object properties" do
    tracker = track(JSON.parse(%({"a":1,"b":2})))
    change = tracker.begin_change
    change.state.delete("a")
    tracker.adopt(change.prepare)
    tracker.value.should eq JSON.parse(%({"b":2}))
  end

  describe "array mutators" do
    it "pushes, pops, shifts and unshifts" do
      tracker = track(JSON.parse(%({"arr":[2,3]})))
      change = tracker.begin_change
      change.state["arr"].push(4, 5).should eq 4
      change.state["arr"].unshift(0, 1).should eq 6
      change.state["arr"].pop.should eq JSON::Any.new(5_i64)
      change.state["arr"].shift.should eq JSON::Any.new(0_i64)
      tracker.adopt(change.prepare)
      tracker.value.should eq JSON.parse(%({"arr":[1,2,3,4]}))
    end

    it "splices and deletes by index" do
      tracker = track(JSON.parse(%({"arr":[0,1,2,3]})))
      change = tracker.begin_change
      removed = change.state["arr"].splice(1, 2, "x", "y")
      removed.should eq [JSON::Any.new(1_i64), JSON::Any.new(2_i64)]
      change.state["arr"].delete_at(0).should eq JSON::Any.new(0_i64)
      tracker.adopt(change.prepare)
      tracker.value.should eq JSON.parse(%({"arr":["x","y",3]}))
    end

    it "reverses and sorts in place" do
      tracker = track(JSON.parse(%({"arr":[3,1,2]})))
      change = tracker.begin_change
      change.state["arr"].sort!
      change.state["arr"].reverse!
      tracker.adopt(change.prepare)
      tracker.value.should eq JSON.parse(%({"arr":[3,2,1]}))
    end

    it "sorts with a comparator" do
      tracker = track(JSON.parse(%({"arr":[10,2,30]})))
      change = tracker.begin_change
      change.state["arr"].sort! { |a, b| a.as_i <=> b.as_i }
      tracker.adopt(change.prepare)
      tracker.value.should eq JSON.parse(%({"arr":[2,10,30]}))
    end

    it "reports size and emptiness" do
      tracker = track(JSON.parse(%({"arr":[1]})))
      change = tracker.begin_change
      change.state["arr"].size.should eq 1
      change.state["arr"].empty?.should be_false
      change.state["arr"].pop
      change.state["arr"].empty?.should be_true
    end

    it "rejects mutators on a non-array" do
      tracker = track(JSON.parse(%({"a":1})))
      change = tracker.begin_change
      expect_raises(Exception) { change.state["a"].push(1) }
      expect_raises(Exception) { change.state["a"].pop }
    end
  end
end
