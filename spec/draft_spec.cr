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
end
