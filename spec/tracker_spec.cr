# spec/tracker_spec.cr
require "./spec_helper"

describe LLM::Chord::Delta::Tracker do
  it "keeps a draft alive across fibers and adopts only a prepared change" do
    input = j(%({"count":1,"nested":{"text":"a"},"values":[1]}))
    tracker = Delta.track(input)
    same?(tracker.value, input).should be_true
    change = tracker.begin_change
    change.state["count"] = 2
    done = Channel(Nil).new
    spawn do
      change.state["nested"]["text"] = change.state["nested"]["text"].as_s + "b"
      done.send(nil)
    end
    done.receive
    change.state["values"] << 2
    tracker.value.should eq j(%({"count":1,"nested":{"text":"a"},"values":[1]}))

    prepared = change.prepare
    same?(prepared.base, tracker.value).should be_true
    prepared.value.should eq j(%({"count":2,"nested":{"text":"ab"},"values":[1,2]}))
    tuples(prepared.ops).should eq j(%([["s",["count"],2],["a",["nested","text"],"b"],["p",["values"],1,0,[2]]]))
    expect_raises(OverlayError) { change.state }
    tracker.value.should eq input

    tracker.adopt(prepared)
    same?(tracker.value, prepared.value).should be_true
    tracker.revision.should eq 1
  end

  it "aborts and revokes without changing the committed value" do
    tracker = Delta.track(j(%({"child":{"value":1}})))
    change = tracker.begin_change
    child = change.state["child"]
    child["value"] = 2
    change.abort
    tracker.value["child"]["value"].should eq JSON::Any.new(1_i64)
    expect_raises(OverlayError, /settled/) { child["value"] }
    change.abort
    expect_raises(Exception, /settled/) { change.prepare }
  end

  it "grows arrays with explicit nulls and revokes drafts after preparation" do
    tracker = Delta.track(j(%({"values":[1,2]})))
    change = tracker.begin_change
    values = change.state["values"]
    values.size = 4
    prepared = change.prepare
    prepared.value["values"].should eq j("[1,2,null,null]")
    expect_raises(OverlayError) { values.size }
    tracker.adopt(prepared)
  end

  it "normalizes a deep no-op to exact previous identity" do
    tracker = Delta.track(j(%({"value":{"nested":[1,2]}})))
    change = tracker.begin_change
    change.state["value"] = {"nested" => [1, 2]}
    prepared = change.prepare
    same?(prepared.value, prepared.base).should be_true
    prepared.ops.should be_empty
    tracker.adopt(prepared)
    same?(tracker.value, prepared.base).should be_true
  end

  it "does not dirty read-only traversals" do
    tracker = Delta.track(j(%({"a":{"b":{"c":[1,{"d":2}]}}})))
    change = tracker.begin_change
    change.state["a"]["b"]["c"][1]["d"].as_i.should eq 2
    change.state["a"].as_h["b"]["c"].as_a.size.should eq 2
    prepared = change.prepare
    prepared.ops.should be_empty
    same?(prepared.value, tracker.value).should be_true
  end

  it "takes immutable ownership of replacement input and normalizes no-ops" do
    tracker = Delta.track(j(%({"nested":{"value":1}})))
    replacement = j(%({"nested":{"value":2}}))
    prepared = tracker.prepare_replace(replacement)
    same?(prepared.value, replacement).should be_true
    tuples(prepared.ops).should eq j(%([["r",{"nested":{"value":2}}]]))
    same?(prepared.ops[0].as(Op::Replace).value, replacement).should be_true
    tracker.adopt(prepared)

    no_op = tracker.prepare_replace(j(%({"nested":{"value":2}})))
    same?(no_op.value, tracker.value).should be_true
    no_op.ops.should be_empty
  end

  it "shares immutable operation placements with the prepared candidate" do
    tracker = Delta.track(j(%({"rows":[]})))
    change = tracker.begin_change
    change.state["rows"] << {"id" => 1}
    prepared = change.prepare
    splice = prepared.ops[0].as(Op::Splice)
    same?(splice.items[0], prepared.value["rows"][0]).should be_true
  end

  it "shares unchanged subtrees between revisions" do
    tracker = Delta.track(j(%({"changed":{"value":1},"retained":{"value":2}})))
    previous = tracker.value
    change = tracker.begin_change
    change.state["changed"]["value"] = 3
    tracker.adopt(change.prepare)
    same?(tracker.value["retained"], previous["retained"]).should be_true
    same?(tracker.value["changed"], previous["changed"]).should be_false
    previous.should eq j(%({"changed":{"value":1},"retained":{"value":2}}))
  end

  it "rejects foreign, stale, and repeated preparations while allowing competing changes" do
    first = Delta.track(j(%({"value":0})))
    second = Delta.track(j(%({"value":0})))
    change = first.begin_change
    competing = first.begin_change
    change.state["value"] = 1
    competing.state["value"] = 2
    prepared = change.prepare
    competing_prepared = competing.prepare
    expect_raises(Exception, /different tracker/) { second.adopt(prepared) }
    first.adopt(prepared)
    expect_raises(Exception, /already been used/) { first.adopt(prepared) }
    expect_raises(Exception, /stale/) { first.adopt(competing_prepared) }

    stale = first.prepare_replace(j(%({"value":2})))
    winner = first.prepare_replace(j(%({"value":3})))
    first.adopt(winner)
    expect_raises(Exception, /stale/) { first.adopt(stale) }
    expect_raises(Exception, /stale/) { first.adopt(stale) }
  end

  it "invalidates competing open overlays" do
    tracker = Delta.track(j(%({"value":0,"nested":{"x":1}})))
    loser = tracker.begin_change
    held = loser.state["nested"]
    winner = tracker.begin_change
    winner.state["value"] = 1
    tracker.adopt(winner.prepare)
    expect_raises(OverlayError) { held["x"] }
    expect_raises(OverlayError) { loser.state }
    expect_raises(OverlayError) { loser.prepare }
  end

  it "invalidates a prepared result when its change is aborted" do
    tracker = Delta.track(j(%({"value":0})))
    change = tracker.begin_change
    change.state["value"] = 1
    prepared = change.prepare
    change.abort
    expect_raises(Exception, /aborted/) { tracker.adopt(prepared) }
    change.abort
  end

  it "rejects an aborted preparation and keeps it readable" do
    tracker = Delta.track(j(%({"value":0})))
    change = tracker.begin_change
    change.state["value"] = 1
    prepared = change.prepare
    prepared.abort
    expect_raises(Exception, /aborted/) { tracker.adopt(prepared) }
    prepared.value.should eq j(%({"value":1}))
  end

  it "makes competing same-base preparations stale after adopting a no-op" do
    tracker = Delta.track(j(%({"value":{"count":1}})))
    first = tracker.prepare_replace(j(%({"value":{"count":1}})))
    competing = tracker.prepare_replace(j(%({"value":{"count":1}})))
    same?(first.value, first.base).should be_true
    tracker.adopt(first)
    tracker.revision.should eq 1
    expect_raises(Exception, /already been used/) { tracker.adopt(first) }
    expect_raises(Exception, /stale/) { tracker.adopt(competing) }
  end

  it "rejects primitive roots" do
    expect_raises(ArgumentError) { Delta.track(JSON::Any.new(1_i64)) }
    expect_raises(ArgumentError) { Delta.track(j("{}")).prepare_replace(JSON::Any.new("x")) }
  end

  it "emits append and rolling-window string operations" do
    tracker = Delta.track(j(%({"text":"abcdefgh"})))
    change = tracker.begin_change
    change.state["text"] = change.state["text"].as_s + "ij"
    prepared = change.prepare
    tuples(prepared.ops).should eq j(%([["a",["text"],"ij"]]))
    tracker.adopt(prepared)
    change = tracker.begin_change
    change.state["text"] = change.state["text"].as_s[3..] + "xyz"
    tuples(change.prepare.ops).should eq j(%([["t",["text"],3],["a",["text"],"xyz"]]))
  end

  it "matches detached replay after randomized transactions" do
    random = Random.new(42)
    tracker = Delta.track(j(%({"rows":[],"meta":{"count":0,"log":""}})))
    replica = Json.deep_copy(tracker.value)
    encoder = Encoder.new
    decoder = Decoder.new
    200.times do |round|
      change = tracker.begin_change
      rows = change.state["rows"]
      random.rand(1..4).times do
        case random.rand(8)
        when 0 then rows << {"id" => round, "tags" => ["t#{round}"]}
        when 1 then rows.unshift({"id" => -round})
        when 2 then rows.pop
        when 3 then rows.shift
        when 4 then rows.reverse!
        when 5 then rows[0]?.try { |row| row["id"] = random.rand(100) }
        when 6 then rows.splice(random.rand(0..rows.size), random.rand(0..2), {"id" => round * 10})
        else        change.state["meta"]["log"] = change.state["meta"]["log"].as_s + "x"
        end
      end
      change.state["meta"]["count"] = round
      prepared = change.prepare
      tracker.adopt(prepared)
      replica = Delta.apply(replica, decoder.decode(JSON.parse(encoder.encode(prepared.ops).to_json).as_a))
      Json.equal?(replica, tracker.value).should be_true
    end
  end
end
