# spec/state_spec.cr
require "./spec_helper"
include LLM::Chord

private class FakeAttachment < LLM::Chord::ReplicatedStateSourceAttachment
  getter disposed = false

  def initialize(@snapshot : LLM::Chord::Snapshot)
    @frames = [] of LLM::Chord::SourceFrame
    @listener = nil.as((LLM::Chord::SourceFrame -> Nil)?)
  end

  def snapshot : LLM::Chord::Snapshot
    @snapshot
  end

  def activate(&listener : LLM::Chord::SourceFrame -> Nil) : Nil
    @listener = listener
    buffered = @frames
    @frames = [] of LLM::Chord::SourceFrame
    buffered.each { |frame| listener.call(frame) }
  end

  def dispose : Nil
    @disposed = true
  end

  def emit(cursor : Int64, value : JSON::Any) : Nil
    frame = LLM::Chord::SourceFrame.new(cursor, value)
    if listener = @listener
      listener.call(frame)
    else
      @frames << frame
    end
  end
end

private class FakeSource < LLM::Chord::ReplicatedStateSource
  def initialize(@attachment : FakeAttachment); end

  def attach : LLM::Chord::ReplicatedStateSourceAttachment
    @attachment
  end
end

describe LLM::Chord do
  describe ".replicated_state (authoritative)" do
    it "starts at the initial value" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      state.value.should eq JSON.parse(%({"n":0}))
    end

    it "delivers a hydrate snapshot on subscribe" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      deliveries = [] of LLM::Chord::Delivery
      state.subscribe do |_value, delivery|
        deliveries << delivery
      end
      deliveries.size.should eq 1
      deliveries[0].kind.should eq LLM::Chord::DeliveryKind::Hydrate
      deliveries[0].sequence.should eq 0
    end

    it "publishes an update on a real change" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      deliveries = [] of LLM::Chord::Delivery
      state.subscribe do |_value, delivery|
        deliveries << delivery
      end
      state.change { |draft| draft["n"] = 1 }
      deliveries.size.should eq 2
      deliveries[1].kind.should eq LLM::Chord::DeliveryKind::Update
      deliveries[1].sequence.should eq 1
      state.value.should eq JSON.parse(%({"n":1}))
    end

    it "does not publish a no-op change" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      deliveries = [] of LLM::Chord::Delivery
      state.subscribe do |_value, delivery|
        deliveries << delivery
      end
      state.change { |draft| draft["n"] = 0 }
      deliveries.size.should eq 1
    end

    it "publishes a real replace and is silent on a no-op" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      deliveries = [] of LLM::Chord::Delivery
      state.subscribe do |_value, delivery|
        deliveries << delivery
      end
      state.replace(JSON.parse(%({"n":1})))
      deliveries.size.should eq 2
      state.replace(JSON.parse(%({"n":1})))
      deliveries.size.should eq 2
    end

    it "stops delivery after unsubscribe" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      count = 0
      unsub = state.subscribe do |_value, _delivery|
        count += 1
      end
      unsub.call
      state.change { |draft| draft["n"] = 1 }
      count.should eq 1
    end

    it "queues reentrant changes in order" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      seen = [] of Int32
      state.subscribe do |value, delivery|
        seen << value["n"].as_i
        if delivery.kind == LLM::Chord::DeliveryKind::Hydrate
          state.change { |draft| draft["n"] = 1 }
          state.change { |draft| draft["n"] = 2 }
        end
      end
      seen.should eq [0, 1, 2]
    end

    it "delivers monotonic sequences" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      sequences = [] of Int32
      state.subscribe do |_value, delivery|
        sequences << delivery.sequence
      end
      state.change { |draft| draft["n"] = 1 }
      state.change { |draft| draft["n"] = 2 }
      sequences.should eq [0, 1, 2]
    end

    it "rejects a reentrant change" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      expect_raises(Exception) do
        state.change do |_draft|
          state.change { |inner| inner["n"] = 1 }
        end
      end
    end

    it "rejects a reentrant replace" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      expect_raises(Exception) do
        state.change do |_draft|
          state.replace(JSON.parse(%({"n":1})))
        end
      end
    end

    it "aborts a change whose mutator raises" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))
      deliveries = [] of LLM::Chord::Delivery
      state.subscribe { |_value, delivery| deliveries << delivery }
      expect_raises(Exception) do
        state.change do |draft|
          draft["n"] = 1
          raise "boom"
        end
      end
      state.value.should eq JSON.parse(%({"n":0}))
      deliveries.size.should eq 1
    end

    it "routes listener errors to on_error" do
      errors = [] of Exception
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), ->(ex : Exception) { errors << ex })
      state.subscribe do |_value, _delivery|
        raise "boom"
      end
      errors.size.should eq 1
      errors[0].message.should eq "boom"
    end
  end

  describe ".replicated_state (source)" do
    it "hydrates from a snapshot and delivers frames" do
      snapshot = LLM::Chord::Snapshot.new(JSON.parse(%({"n":0})), 10_i64)
      attachment = FakeAttachment.new(snapshot)
      state = LLM::Chord.replicated_state(FakeSource.new(attachment))
      values = [] of JSON::Any
      state.subscribe do |value, _delivery|
        values << value
      end
      values.should eq [JSON.parse(%({"n":0}))]
      attachment.emit(11_i64, JSON.parse(%({"n":1})))
      attachment.emit(12_i64, JSON.parse(%({"n":2})))
      values.should eq [JSON.parse(%({"n":0})), JSON.parse(%({"n":1})), JSON.parse(%({"n":2}))]
    end

    it "reports a cursor gap" do
      snapshot = LLM::Chord::Snapshot.new(JSON.parse(%({"n":0})), 10_i64)
      attachment = FakeAttachment.new(snapshot)
      errors = [] of Exception
      state = LLM::Chord.replicated_state(FakeSource.new(attachment), ->(ex : Exception) { errors << ex })
      state.subscribe do |_value, _delivery|
      end
      attachment.emit(12_i64, JSON.parse(%({"n":1})))
      errors.size.should eq 1
    end

    it "disposes idempotently and ignores frames after dispose" do
      snapshot = LLM::Chord::Snapshot.new(JSON.parse(%({"n":0})), 10_i64)
      attachment = FakeAttachment.new(snapshot)
      state = LLM::Chord.replicated_state(FakeSource.new(attachment))
      values = [] of JSON::Any
      state.subscribe { |value, _delivery| values << value }
      state.dispose
      state.dispose
      attachment.disposed.should be_true
      attachment.emit(11_i64, JSON.parse(%({"n":1})))
      values.size.should eq 1
    end
  end

  describe ".replicated_state (async)" do
    it "delivers hydrate then updates in order on a fiber" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), async: true)
      done = Channel(Nil).new
      seen = [] of Int64
      state.subscribe do |value, _delivery|
        seen << value["n"].as_i
        done.send(nil)
      end
      done.receive
      state.change { |draft| draft["n"] = 1 }
      done.receive
      seen.should eq [0_i64, 1_i64]
    end

    it "returns from change without waiting for a slow listener" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), async: true)
      entered = Channel(Nil).new
      release = Channel(Nil).new
      state.subscribe do |_value, delivery|
        if delivery.kind == LLM::Chord::DeliveryKind::Hydrate
          entered.send(nil)
          release.receive
        end
      end
      entered.receive
      state.change { |draft| draft["n"] = 1 }
      state.value["n"].as_i.should eq 1_i64
      release.send(nil)
    end

    it "routes listener errors to on_error" do
      errors = Channel(Exception).new
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), ->(ex : Exception) { errors.send(ex) }, async: true)
      state.subscribe do |_value, _delivery|
        raise "boom"
      end
      errors.receive.message.should eq "boom"
    end

    it "stops delivery after unsubscribe" do
      state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), async: true)
      seen = [] of Int64
      hydrated = Channel(Nil).new
      unsub = state.subscribe do |value, _delivery|
        seen << value["n"].as_i
        hydrated.send(nil)
      end
      hydrated.receive
      unsub.call
      state.change { |draft| draft["n"] = 1 }
      seen.should eq [0_i64]
    end
  end
end
