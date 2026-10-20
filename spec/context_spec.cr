# spec/context_spec.cr
require "./spec_helper"

describe LLM::Chord::Context do
  it "provides distinct empty root contexts" do
    key = ContextKey(String).new("value")
    Context::TODO.should_not be Context::BACKGROUND
    Context::TODO.abort_signal.should be_nil
    Context::TODO.telemetry.should be Telemetry::NOOP
    Context::BACKGROUND.telemetry.should be Telemetry::NOOP
    Context::TODO.value(key).should be_nil
    Context::BACKGROUND.to_s.should eq "[Context BACKGROUND_CONTEXT]"
    Context::TODO.to_s.should eq "[Context TODO_CONTEXT]"
  end

  it "layers typed values without modifying parents" do
    first_key = ContextKey(String).new("first")
    second_key = ContextKey(Int32).new("second")
    first = Context::BACKGROUND.with_value(first_key, "one")
    second = first.with_value(second_key, 2)
    replaced = second.with_value(first_key, "updated")
    Context::BACKGROUND.value(first_key).should be_nil
    first.value(first_key).should eq "one"
    first.value(second_key).should be_nil
    second.value(first_key).should eq "one"
    second.value(second_key).should eq 2
    replaced.value(first_key).should eq "updated"
    second.value(first_key).should eq "one"
    replaced.to_s.should eq "[Context BACKGROUND_CONTEXT].WithValue(first).WithValue(second).WithValue(first)"
  end

  it "distinguishes keys by identity, not description" do
    first = ContextKey(String).new("same")
    second = ContextKey(String).new("same")
    context = Context::BACKGROUND.with_value(first, "value")
    context.value(first).should eq "value"
    context.value(second).should be_nil
    ContextKey(String).new.description.should eq "anonymous"
  end

  it "carries reference values" do
    key = ContextKey(Array(Int32)).new("list")
    list = [1, 2]
    Context::BACKGROUND.with_value(key, list).value(key).should be list
  end

  it "inherits parent cancellation and isolates child cancellation" do
    parent_controller = AbortController.new
    parent = Context::BACKGROUND.with_abort_signal(parent_controller.signal)
    child, child_controller = parent.with_cancel
    sibling, _ = parent.with_cancel
    heard = 0
    child.abort_signal.not_nil!.on_abort { heard += 1 }

    child_controller.abort("child")
    child.abort_signal.not_nil!.aborted?.should be_true
    child.abort_signal.not_nil!.reason.not_nil!.message.should eq "child"
    sibling.abort_signal.not_nil!.aborted?.should be_false
    parent.abort_signal.not_nil!.aborted?.should be_false
    heard.should eq 1

    parent_controller.abort("parent")
    sibling.abort_signal.not_nil!.aborted?.should be_true
    sibling.abort_signal.not_nil!.reason.not_nil!.message.should eq "parent"
    child.abort_signal.not_nil!.reason.not_nil!.message.should eq "child"
    heard.should eq 1
  end

  it "combines an already aborted parent at once" do
    controller = AbortController.new
    reason = AbortError.new("early")
    controller.abort(reason)
    child, _ = Context::BACKGROUND.with_abort_signal(controller.signal).with_cancel
    child.abort_signal.not_nil!.aborted?.should be_true
    child.abort_signal.not_nil!.reason.should be reason
  end

  it "masks caller cancellation for mandatory cleanup" do
    controller = AbortController.new
    key = ContextKey(String).new("value")
    context = Context::BACKGROUND.with_abort_signal(controller.signal).with_value(key, "preserved")
    cleanup = context.without_abort_signal
    controller.abort
    context.abort_signal.not_nil!.aborted?.should be_true
    context.abort_signal.not_nil!.reason.should be_a AbortError
    cleanup.abort_signal.should be_nil
    cleanup.value(key).should eq "preserved"
  end

  it "removes abort listeners and ignores listeners added after abort" do
    controller = AbortController.new
    calls = [] of String
    remove = controller.signal.on_abort { calls << "removed" }
    controller.signal.on_abort { calls << "kept" }
    remove.call
    controller.abort
    controller.abort
    controller.signal.on_abort { calls << "late" }
    calls.should eq ["kept"]
    expect_raises(AbortError) { controller.signal.throw_if_aborted }
  end

  it "derives telemetry independently from values and cancellation" do
    telemetry = Telemetry::InMemoryTelemetryContext.new
    other = Telemetry::InMemoryTelemetryContext.new
    telemetry.start_span(Telemetry::SpanOptions.new("caller")) do |parent|
      other.start_span(Telemetry::SpanOptions.new("other")) do |other_span|
        key = ContextKey(String).new("principal")
        controller = AbortController.new
        base = Context::BACKGROUND.with_abort_signal(controller.signal).with_value(key, "owner")
        context = base.with_telemetry(parent)
        replaced = context.with_telemetry(other_span)
        base.telemetry.should be Telemetry::NOOP
        context.telemetry.should be parent
        replaced.telemetry.should be other_span
        replaced.value(key).should eq "owner"
        replaced.abort_signal.should be base.abort_signal
        context.without_abort_signal.telemetry.should be parent
        context.trace_in(Telemetry::SpanOptions.new("outer")) do |child|
          child.value(key).should eq "owner"
          child.abort_signal.should be context.abort_signal
          child.telemetry.add_event("started")
          child.trace_in("inner") do |nested|
            nested.telemetry.add_link(Telemetry::SpanLink.new(child.telemetry))
            42
          end
        end.should eq 42
        caller, outer, inner = telemetry.recorded_spans
        outer.parent_id.should eq caller.id
        inner.parent_id.should eq outer.id
        inner.links[0].context.should eq outer.context
        outer.events.map(&.name).should eq ["started"]
        controller.abort
        context.abort_signal.not_nil!.aborted?.should be_true
      end
    end
  end

  it "isolates concurrent trace_in branches and preserves results and errors" do
    telemetry = Telemetry::InMemoryTelemetryContext.new
    telemetry.start_span(Telemetry::SpanOptions.new("caller")) do |parent|
      context = Context::BACKGROUND.with_telemetry(parent)
      gate = Channel(Nil).new
      results = Channel(String).new(2)
      spawn do
        results.send(context.trace_in("first") do |child|
          gate.receive
          child.trace_in("first.child") { "first" }
        end)
      end
      spawn do
        results.send(context.trace_in("second") do |child|
          value = child.trace_in("second.child") { "second" }
          gate.send(nil)
          value
        end)
      end
      [results.receive, results.receive].sort.should eq ["first", "second"]
      spans = telemetry.recorded_spans
      %w[first second].each do |name|
        branch = spans.find! { |span| span.name == name }
        spans.find! { |span| span.name == "#{name}.child" }.parent_id.should eq branch.id
      end
      failure = ArgumentError.new("same value")
      raised = expect_raises(ArgumentError) { context.trace_in("throw") { raise failure } }
      raised.should be failure
      Context::BACKGROUND.trace_in("noop") do |child|
        child.telemetry.add_link(Telemetry::SpanLink.new(parent))
        42
      end.should eq 42
    end
  end

  it "stops waiting when the invocation is cancelled" do
    controller = AbortController.new
    context = Context::BACKGROUND.with_abort_signal(controller.signal)
    work = Channel(String).new(1)
    cancellation = AbortError.new("cancelled")
    spawn { controller.abort(cancellation) }
    raised = expect_raises(AbortError) { context.await(work) }
    raised.should be cancellation
    work.send("completed later")
    work.receive.should eq "completed later"
    ready = Channel(String).new(1)
    ready.send("completed")
    Context::BACKGROUND.await(ready).should eq "completed"
    expect_raises(AbortError) { context.await(ready) }
  end

  it "awaits blocks on their own fiber and propagates their errors" do
    Context::BACKGROUND.await { 1 + 1 }.should eq 2
    expect_raises(ArgumentError, "inner") { Context::BACKGROUND.await { raise ArgumentError.new("inner") } }
    controller = AbortController.new
    context = Context::BACKGROUND.with_abort_signal(controller.signal)
    finished = Channel(Nil).new(1)
    release = Channel(Nil).new
    spawn { controller.abort }
    expect_raises(AbortError) do
      context.await do
        release.receive
        finished.send(nil)
      end
    end
    release.send(nil)
    finished.receive
  end
end
