# spec/state_spec.cr
require "./spec_helper"

private def eventually(& : -> Bool) : Nil
  1000.times do
    return if yield
    sleep 1.millisecond
  end
  fail "condition was not met"
end

private class TestAttachment < ReplicatedStateSourceAttachment
  getter snapshot : Snapshot
  @buffer = [] of SourceFrame
  @listener : Proc(SourceFrame, Nil)? = nil
  @activated = false
  @disposed = false

  def initialize(@snapshot : Snapshot, @on_dispose : Proc(TestAttachment, Nil)); end

  def activate(&listener : SourceFrame -> Nil) : Nil
    raise "attachment is already active" if @activated
    @activated = true
    @listener = listener
    frames = @buffer.dup
    @buffer.clear
    frames.each { |frame| listener.call(frame) }
  end

  def publish(frame : SourceFrame) : Nil
    return if @disposed
    if listener = @listener
      listener.call(frame)
    else
      @buffer << frame
    end
  end

  def dispose : Nil
    return if @disposed
    @disposed = true
    @buffer.clear
    @on_dispose.call(self)
  end
end

private class TestSource < ReplicatedStateSource
  getter attachments = [] of TestAttachment
  property on_attach : Proc(Nil)? = nil
  property fail_dispose = false

  def initialize(@value : JSON::Any, @cursor : Int64 = 0_i64); end

  def attach : ReplicatedStateSourceAttachment
    attachment = TestAttachment.new(Snapshot.new(@value, @cursor), ->(done : TestAttachment) do
      @attachments.delete(done)
      raise "dispose failed" if @fail_dispose
      nil
    end)
    @attachments << attachment
    @on_attach.try(&.call)
    attachment
  end

  def commit(value : JSON::Any, context : Context = Context::BACKGROUND, cursor : Int64 = @cursor + 1) : Nil
    @value = value
    @cursor = cursor
    frame = SourceFrame.new(cursor, value, [Op::Set.new(path("value"), value["value"])] of Op, context)
    @attachments.dup.each(&.publish(frame))
  end
end

private def value_of(number : Int) : JSON::Any
  doc(value: number)
end

describe LLM::Chord::MutableReplicatedState do
  it "publishes one immutable structurally shared revision" do
    state = LLM::Chord.replicated_state(j(%({"changed":{"value":1},"retained":{"value":2}})))
    previous = state.value
    deliveries = [] of Int64
    state.subscribe { |_value, _context, delivery| deliveries << delivery.sequence }
    state.change(Context::BACKGROUND) do |draft|
      draft["changed"]["value"] = 3
      draft["changed"]["value"] = 4
    end
    state.value.should eq j(%({"changed":{"value":4},"retained":{"value":2}}))
    same?(state.value, previous).should be_false
    same?(state.value["changed"], previous["changed"]).should be_false
    same?(state.value["retained"], previous["retained"]).should be_true
    deliveries.should eq [0, 1]
  end

  it "rolls back callback failures and revokes escaped drafts" do
    state = LLM::Chord.replicated_state(j(%({"nested":{"value":1}})))
    previous = state.value
    escaped = nil.as(Draft?)
    expect_raises(Exception, "stop") do
      state.change(Context::BACKGROUND) do |draft|
        escaped = draft["nested"]
        draft["nested"]["value"] = 2
        raise "stop"
      end
    end
    same?(state.value, previous).should be_true
    expect_raises(OverlayError) { escaped.not_nil!["value"] }
  end

  it "revokes drafts after a successful change" do
    state = LLM::Chord.replicated_state(j(%({"nested":{"value":1}})))
    escaped = nil.as(Draft?)
    state.change(Context::BACKGROUND) { |draft| escaped = draft["nested"] }
    expect_raises(OverlayError) { escaped.not_nil!["value"] = 5 }
    state.value.should eq j(%({"nested":{"value":1}}))
  end

  it "rejects nested changes and replacements without losing the outer rollback" do
    state = LLM::Chord.replicated_state(j(%({"left":0,"right":0})))
    expect_raises(Exception, /reentrantly/) do
      state.change(Context::BACKGROUND) do |draft|
        draft["left"] = 1
        state.change(Context::BACKGROUND) { |nested| nested["right"] = 2 }
      end
    end
    state.value.should eq j(%({"left":0,"right":0}))
    expect_raises(Exception, /change callback/) do
      state.change(Context::BACKGROUND) { state.replace(Context::BACKGROUND, j(%({"left":1,"right":2}))) }
    end
    state.value.should eq j(%({"left":0,"right":0}))
  end

  it "queues listener-triggered changes in sequence order" do
    state = LLM::Chord.replicated_state(j(%({"value":0})))
    deliveries = [] of Tuple(Int64, Int64)
    late = [] of Tuple(DeliveryKind, Int64)
    nested = false
    state.subscribe do |_value, _context, delivery|
      next if delivery.kind.hydrate? || nested
      nested = true
      state.change(Context::BACKGROUND) { |draft| draft["value"] = 2 }
      state.subscribe { |_inner, _context, inner_delivery| late << {inner_delivery.kind, inner_delivery.sequence} }
    end
    state.subscribe do |value, _context, delivery|
      deliveries << {value["value"].as_i64, delivery.sequence} if delivery.kind.update?
    end
    state.change(Context::BACKGROUND) { |draft| draft["value"] = 1 }
    deliveries.should eq [{1, 1}, {2, 2}]
    late.should eq [{DeliveryKind::Hydrate, 2}]
  end

  it "copies assigned values by value" do
    external = j(%({"value":1}))
    state = LLM::Chord.replicated_state(j(%({"left":null,"right":null})))
    state.change(Context::BACKGROUND) do |draft|
      draft["left"] = external
      draft["right"] = external
      draft["left"]["value"] = 2
    end
    external.should eq j(%({"value":1}))
    state.value.should eq j(%({"left":{"value":2},"right":{"value":1}}))
    same?(state.value["left"], state.value["right"]).should be_false
  end

  it "takes immutable ownership of alias-free replacements" do
    state = LLM::Chord.replicated_state(j(%({"left":{"value":1},"right":{"value":2}})))
    replacement = j(%({"left":{"value":1},"right":{"value":1}}))
    state.replace(Context::BACKGROUND, replacement)
    same?(state.value, replacement).should be_true
    state.change(Context::BACKGROUND) { |draft| draft["left"]["value"] = 9 }
    state.value.should eq j(%({"left":{"value":9},"right":{"value":1}}))
  end

  it "replaces atomically and ignores deeply equal replacements" do
    state = LLM::Chord.replicated_state(j(%({"value":{"nested":1},"retained":{"nested":2}})))
    previous = state.value
    deliveries = 0
    state.subscribe { deliveries += 1 }
    state.replace(Context::BACKGROUND, j(%({"value":{"nested":1},"retained":{"nested":2}})))
    same?(state.value, previous).should be_true
    deliveries.should eq 1
    shallow = previous.as_h.dup
    shallow["value"] = j(%({"nested":2}))
    state.replace(Context::BACKGROUND, JSON::Any.new(shallow))
    state.value.should eq j(%({"value":{"nested":2},"retained":{"nested":2}}))
    same?(state.value["retained"], previous["retained"]).should be_true
    deliveries.should eq 2
  end

  it "passes the change context to update listeners" do
    key = ContextKey(String).new("request")
    context = Context::BACKGROUND.with_value(key, "abc")
    state = LLM::Chord.replicated_state(j(%({"n":0})))
    seen = [] of String?
    state.subscribe { |_value, ctx, _delivery| seen << ctx.value(key) }
    state.change(context) { |draft| draft["n"] = 1 }
    state.replace(context, j(%({"n":2})))
    seen.should eq [nil, "abc", "abc"]
  end

  it "does not publish no-op changes" do
    state = LLM::Chord.replicated_state(j(%({"n":0})))
    count = 0
    state.subscribe { count += 1 }
    state.change(Context::BACKGROUND) { |draft| draft["n"] = 0 }
    count.should eq 1
  end

  it "serializes reentrant hydration and update callbacks" do
    state = LLM::Chord.replicated_state(j(%({"value":0})))
    events = [] of String
    state.subscribe do |value, _context, _delivery|
      number = value["value"].as_i64
      events << "start:#{number}"
      state.replace(Context::BACKGROUND, value_of(number + 1)) if number < 2
      events << "end:#{number}"
    end
    events.should eq ["start:0", "end:0", "start:1", "end:1", "start:2", "end:2"]
  end

  it "awaits hydration and each async update independently of other subscribers" do
    state = LLM::Chord.replicated_state(value_of(0))
    hydration = Channel(Nil).new
    update = Channel(Nil).new
    events = [] of String
    fast = [] of Int64
    state.subscribe(async: true) do |value, _context, _delivery|
      number = value["value"].as_i64
      events << "start:#{number}"
      hydration.receive if number == 0
      update.receive if number == 1
      events << "end:#{number}"
    end
    state.subscribe { |value, _context, _delivery| fast << value["value"].as_i64 }
    state.replace(Context::BACKGROUND, value_of(1))
    state.replace(Context::BACKGROUND, value_of(2))
    fast.should eq [0, 1, 2]
    state.value.should eq value_of(2)
    eventually { events == ["start:0"] }
    hydration.send(nil)
    eventually { events == ["start:0", "end:0", "start:1"] }
    update.send(nil)
    eventually { events == ["start:0", "end:0", "start:1", "end:1", "start:2", "end:2"] }
  end

  it "bounds pending async deliveries" do
    [100, 101, 102, 201, 202].each do |count|
      state = LLM::Chord.replicated_state(value_of(0))
      gate = Channel(Nil).new
      received = [] of Int64
      state.subscribe(async: true) do |value, _context, _delivery|
        received << value["value"].as_i64
        gate.receive if value["value"].as_i64 == 0
      end
      (1..count).each { |number| state.replace(Context::BACKGROUND, value_of(number)) }
      eventually { received == [0_i64] }
      gate.send(nil)
      first = ((count - 1) // 100) * 100 + 1
      expected = [0_i64] + (first..count).map(&.to_i64)
      eventually { received == expected }
    end
  end

  it "excludes a running update from overflow and retains exact value, context, and delivery" do
    state = LLM::Chord.replicated_state(value_of(0))
    gate = Channel(Nil).new
    key = ContextKey(String).new("tag")
    context = Context::BACKGROUND.with_value(key, "newest")
    received = [] of Tuple(JSON::Any, Context, Delivery)
    state.subscribe(async: true) do |value, ctx, delivery|
      received << {value, ctx, delivery}
      gate.receive if value["value"].as_i64 == 1
    end
    eventually { received.size == 1 }
    (1...102).each { |number| state.replace(Context::BACKGROUND, value_of(number)) }
    state.replace(context, value_of(102))
    adopted = state.value
    state.replace(Context::BACKGROUND, value_of(103))
    eventually { received.map(&.[0]["value"].as_i64) == [0, 1] }
    gate.send(nil)
    eventually { received.size == 4 }
    received.map(&.[0]["value"].as_i64).should eq [0, 1, 102, 103]
    same?(received[2][0], adopted).should be_true
    received[2][1].should be context
    received[2][2].sequence.should eq 102
    received[2][2].kind.update?.should be_true
  end

  it "unsubscribes without joining or aborting the running callback" do
    state = LLM::Chord.replicated_state(value_of(0))
    gate = Channel(Nil).new
    received = [] of Int64
    completed = false
    stop = state.subscribe(async: true) do |value, _context, _delivery|
      received << value["value"].as_i64
      if value["value"].as_i64 == 1
        gate.receive
        completed = true
      end
    end
    eventually { received == [0_i64] }
    state.replace(Context::BACKGROUND, value_of(1))
    state.replace(Context::BACKGROUND, value_of(2))
    eventually { received == [0_i64, 1_i64] }
    stop.call
    state.replace(Context::BACKGROUND, value_of(3))
    completed.should be_false
    gate.send(nil)
    eventually { completed }
    received.should eq [0, 1]
  end

  it "treats two subscriptions of the same callback independently" do
    state = LLM::Chord.replicated_state(value_of(0))
    received = [] of Int64
    listener = StateListener.new { |value, _context, _delivery| received << value["value"].as_i64 }
    stop_first = state.subscribe { |value, context, delivery| listener.call(value, context, delivery) }
    stop_second = state.subscribe { |value, context, delivery| listener.call(value, context, delivery) }
    stop_first.call
    stop_first.call
    state.replace(Context::BACKGROUND, value_of(1))
    received.should eq [0, 0, 1]
    stop_second.call
  end

  it "keeps delivering when a listener unsubscribes another during delivery" do
    state = LLM::Chord.replicated_state(value_of(0))
    received = [] of Int64
    stop_second = nil.as(Proc(Nil)?)
    state.subscribe { |_value, _context, delivery| stop_second.try(&.call) if delivery.kind.update? }
    stop_second = state.subscribe { |value, _context, _delivery| received << value["value"].as_i64 }
    state.subscribe { |value, _context, _delivery| received << -value["value"].as_i64 }
    state.replace(Context::BACKGROUND, value_of(1))
    received.should eq [0, 0, -1]
  end
end

describe LLM::Chord::AttachedReplicatedState do
  it "captures before activation and drains queued commits in order" do
    source = TestSource.new(value_of(0), 10_i64)
    second = value_of(2)
    source.on_attach = -> do
      source.commit(value_of(1))
      source.commit(second)
      nil
    end
    state = LLM::Chord.replicated_state(source)
    deliveries = [] of Tuple(JSON::Any, Int64)
    state.subscribe { |value, _context, delivery| deliveries << {value, delivery.sequence} }
    same?(state.value, second).should be_true
    deliveries.should eq [{second, 2}]
  end

  it "hydrates at sequence zero when attaching after existing commits" do
    source = TestSource.new(value_of(0), 40_i64)
    current = value_of(1)
    source.commit(current)
    state = LLM::Chord.replicated_state(source)
    deliveries = [] of Int64
    state.subscribe { |_value, _context, delivery| deliveries << delivery.sequence }
    same?(state.value, current).should be_true
    deliveries.should eq [0]
  end

  it "publishes exact source values without applying or re-diffing" do
    source = TestSource.new(value_of(0))
    state = LLM::Chord.replicated_state(source)
    published = nil.as(JSON::Any?)
    state.subscribe { |value, _context, delivery| published = value if delivery.kind.update? }
    next_value = value_of(1)
    source.commit(next_value)
    same?(state.value, next_value).should be_true
    same?(published.not_nil!, next_value).should be_true
  end

  it "buffers reentrant frames and skips updates covered by a late hydration" do
    source = TestSource.new(value_of(0))
    state = LLM::Chord.replicated_state(source)
    received = [] of Int64
    late = [] of Tuple(DeliveryKind, Int64, Int64)
    nested = false
    state.subscribe do |_value, _context, delivery|
      next if delivery.kind.hydrate? || delivery.sequence != 1 || nested
      nested = true
      source.commit(value_of(2))
      state.subscribe { |value, _context, inner| late << {inner.kind, inner.sequence, value["value"].as_i64} }
    end
    state.subscribe { |value, _context, delivery| received << value["value"].as_i64 if delivery.kind.update? }
    source.commit(value_of(1))
    received.should eq [1, 2]
    late.should eq [{DeliveryKind::Hydrate, 2, 2}]
  end

  it "reports listener failures without throwing them into the source" do
    source = TestSource.new(value_of(0))
    errors = [] of String
    state = LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error.message.not_nil!; nil })
    received = [] of Int64
    state.subscribe { |_value, _context, delivery| raise "listener failed" if delivery.kind.update? }
    state.subscribe { |value, _context, delivery| received << value["value"].as_i64 if delivery.kind.update? }
    source.commit(value_of(1))
    source.commit(value_of(2))
    received.should eq [1, 2]
    errors.should eq ["listener failed", "listener failed"]
  end

  it "isolates a synchronous hydration failure without removing the subscription" do
    source = TestSource.new(value_of(0))
    errors = [] of String
    state = LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error.message.not_nil!; nil })
    received = [] of Int64
    state.subscribe do |value, _context, _delivery|
      received << value["value"].as_i64
      raise "sync hydration" if value["value"].as_i64 == 0
    end
    source.commit(value_of(1))
    errors.should eq ["sync hydration"]
    received.should eq [0, 1]
  end

  it "observes async listener failures while continuing delivery" do
    source = TestSource.new(value_of(0))
    errors = [] of String
    state = LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error.message.not_nil!; nil })
    gate = Channel(Nil).new
    received = [] of Int64
    fast = [] of Int64
    state.subscribe(async: true) do |value, _context, _delivery|
      number = value["value"].as_i64
      received << number
      if number == 0
        gate.receive
        raise "async hydration"
      end
      raise "update #{number}" if number < 3
    end
    state.subscribe { |value, _context, _delivery| fast << value["value"].as_i64 }
    (1..3).each { |number| source.commit(value_of(number)) }
    gate.send(nil)
    eventually { received == [0_i64, 1_i64, 2_i64, 3_i64] }
    errors.should eq ["async hydration", "update 1", "update 2"]
    fast.should eq [0, 1, 2, 3]
  end

  it "still observes a callback failure after unsubscribe" do
    source = TestSource.new(value_of(0))
    errors = [] of String
    state = LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error.message.not_nil!; nil })
    gate = Channel(Nil).new
    received = [] of Int64
    stop = state.subscribe(async: true) do |value, _context, _delivery|
      received << value["value"].as_i64
      gate.receive
      raise "stopped callback"
    end
    source.commit(value_of(1))
    stop.call
    gate.send(nil)
    eventually { errors == ["stopped callback"] }
    received.should eq [0]
  end

  it "reports cursor gaps, disposes the broken attachment, and ignores later frames" do
    source = TestSource.new(value_of(0), 5_i64)
    errors = [] of String
    state = LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error.message.not_nil!; nil })
    source.commit(value_of(2), Context::BACKGROUND, 7_i64)
    errors[0].should contain "expected 6, received 7"
    source.attachments.should be_empty
    state.value.should eq value_of(0)
    source.commit(value_of(3), Context::BACKGROUND, 8_i64)
    state.value.should eq value_of(0)
  end

  it "aggregates a failed disposal with the contract failure" do
    source = TestSource.new(value_of(0))
    errors = [] of Exception
    LLM::Chord.replicated_state(source, ->(error : Exception) { errors << error; nil })
    source.fail_dispose = true
    source.commit(value_of(1), Context::BACKGROUND, 9_i64)
    aggregate = errors[0].as(AggregateError)
    aggregate.message.should eq "Replicated state source contract failed"
    aggregate.errors.map(&.message).should eq ["Replicated state source cursor has a gap: expected 1, received 9", "dispose failed"]
  end

  it "rejects unsafe snapshot cursors and disposes the attachment" do
    source = TestSource.new(value_of(0), 9_007_199_254_740_992_i64)
    expect_raises(ArgumentError, /safe integer/) { LLM::Chord.replicated_state(source) }
    source.attachments.should be_empty
  end

  it "keeps attachments independent and disposes each idempotently" do
    source = TestSource.new(value_of(0))
    first = LLM::Chord.replicated_state(source)
    second = LLM::Chord.replicated_state(source)
    source.attachments.size.should eq 2
    source.commit(value_of(1))
    first.value["value"].as_i64.should eq 1
    second.value["value"].as_i64.should eq 1
    first.dispose
    first.dispose
    source.attachments.size.should eq 1
    source.commit(value_of(2))
    first.value["value"].as_i64.should eq 1
    second.value["value"].as_i64.should eq 2
    second.dispose
    source.attachments.should be_empty
  end
end
