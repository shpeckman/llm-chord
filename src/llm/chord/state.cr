# src/llm/chord/state.cr
module LLM::Chord
  enum DeliveryKind
    Hydrate
    Update
  end

  struct Delivery
    getter kind : DeliveryKind
    getter sequence : Int64

    def initialize(@kind : DeliveryKind, @sequence : Int64); end
  end

  alias StateListener = Proc(JSON::Any, Context, Delivery, Nil)
  alias ErrorReporter = Proc(Exception, Nil)

  REPORT_ASYNC           = ErrorReporter.new { |error| spawn { raise error } }
  MAX_PENDING_DELIVERIES =                       100
  MAX_SAFE_CURSOR        = 9_007_199_254_740_991_i64

  private struct StateFrame
    getter value : JSON::Any
    getter context : Context
    getter delivery : Delivery

    def initialize(@value : JSON::Any, @context : Context, @delivery : Delivery); end
  end

  private class StateSubscriber
    @pending = Deque(StateFrame).new
    @running = false
    @started = false
    @closed = false

    def initialize(@listener : StateListener, @report : ErrorReporter, @async : Bool); end

    def push(frame : StateFrame) : Nil
      return if @closed
      if @pending.size >= MAX_PENDING_DELIVERIES
        hydration = @started ? nil : @pending.first?
        @pending.clear
        @pending << hydration if hydration
      end
      @pending << frame
    end

    def drain : Nil
      return if @running || @closed
      return unless frame = @pending.shift?
      @running = true
      @started = true
      if @async
        spawn { deliver(frame) }
      else
        deliver(frame)
      end
    end

    def close : Nil
      @closed = true
      @pending.clear
    end

    private def deliver(first : StateFrame) : Nil
      frame = first
      while frame
        begin
          @listener.call(frame.value, frame.context, frame.delivery)
        rescue error
          report(error)
        end
        frame = @closed ? nil : @pending.shift?
      end
      @running = false
    end

    private def report(error : Exception) : Nil
      @report.call(error)
    rescue ex
      REPORT_ASYNC.call(ex)
    end
  end

  private class Publisher
    getter value : JSON::Any
    @sequence = 0_i64
    @subscribers = {} of StateSubscriber => Int64
    @publications = Deque(Tuple(JSON::Any, Int64, Context)).new
    @delivering = false

    def initialize(@value : JSON::Any, @report : ErrorReporter); end

    def subscribe(listener : StateListener, async : Bool) : Proc(Nil)
      subscriber = StateSubscriber.new(listener, @report, async)
      @subscribers[subscriber] = @sequence
      subscriber.push(StateFrame.new(@value, Context::BACKGROUND, Delivery.new(DeliveryKind::Hydrate, @sequence)))
      subscriber.drain
      -> do
        subscriber.close
        @subscribers.delete(subscriber)
        nil
      end
    end

    def publish(value : JSON::Any, context : Context) : Nil
      @value = value
      @sequence += 1
      @publications << {value, @sequence, context}
      return if @delivering
      @delivering = true
      begin
        while publication = @publications.shift?
          published, sequence, origin = publication
          delivery = Delivery.new(DeliveryKind::Update, sequence)
          @subscribers.to_a.each do |(subscriber, hydrated)|
            next if sequence <= hydrated
            subscriber.push(StateFrame.new(published, origin, delivery))
            subscriber.drain
          end
        end
      ensure
        @delivering = false
      end
    end
  end

  abstract class ReplicatedState
    def initialize(@publisher : Publisher); end

    def value : JSON::Any
      @publisher.value
    end

    def subscribe(async : Bool = false, &listener : JSON::Any, Context, Delivery -> Nil) : Proc(Nil)
      @publisher.subscribe(listener, async)
    end
  end

  class MutableReplicatedState < ReplicatedState
    @changing = false

    def initialize(initial : JSON::Any)
      @tracker = Delta.track(initial)
      super(Publisher.new(@tracker.value, REPORT_ASYNC))
    end

    def value : JSON::Any
      @tracker.value
    end

    def change(context : Context, & : Delta::Draft -> _) : Nil
      raise Exception.new("Replicated state cannot be changed reentrantly from a change callback") if @changing
      @changing = true
      prepared = begin
        change = @tracker.begin_change
        begin
          yield change.state
          change.prepare
        rescue error
          change.abort
          raise error
        end
      ensure
        @changing = false
      end
      @tracker.adopt(prepared)
      @publisher.publish(prepared.value, context) unless prepared.ops.empty?
    end

    def replace(context : Context, value : JSON::Any) : Nil
      raise Exception.new("Replicated state cannot be replaced from a change callback") if @changing
      prepared = @tracker.prepare_replace(value)
      @tracker.adopt(prepared)
      @publisher.publish(prepared.value, context) unless prepared.ops.empty?
    end
  end

  struct Snapshot
    getter value : JSON::Any
    getter cursor : Int64

    def initialize(@value : JSON::Any, @cursor : Int64); end
  end

  struct SourceFrame
    getter cursor : Int64
    getter value : JSON::Any
    getter ops : Array(Delta::Op)
    getter context : Context

    def initialize(@cursor : Int64, @value : JSON::Any, @ops : Array(Delta::Op), @context : Context = Context::BACKGROUND); end
  end

  abstract class ReplicatedStateSourceAttachment
    abstract def snapshot : Snapshot
    abstract def activate(&listener : SourceFrame -> Nil) : Nil
    abstract def dispose : Nil
  end

  abstract class ReplicatedStateSource
    abstract def attach : ReplicatedStateSourceAttachment
  end

  class AttachedReplicatedState < ReplicatedState
    @disposed = false

    def self.attach(source : ReplicatedStateSource, on_error : ErrorReporter? = nil) : AttachedReplicatedState
      attachment = source.attach
      begin
        new(attachment, on_error || REPORT_ASYNC)
      rescue error
        begin
          attachment.dispose
        rescue ex
          raise AggregateError.new([error, ex], "Failed to attach replicated state source")
        end
        raise error
      end
    end

    protected def initialize(@attachment : ReplicatedStateSourceAttachment, @on_error : ErrorReporter)
      snapshot = @attachment.snapshot
      assert_cursor(snapshot.cursor, "snapshot")
      @cursor = snapshot.cursor
      super(Publisher.new(snapshot.value, ErrorReporter.new { |error| report(error) }))
      @attachment.activate { |frame| receive(frame) }
    end

    def dispose : Nil
      return if @disposed
      @disposed = true
      @attachment.dispose
    end

    private def receive(frame : SourceFrame) : Nil
      return if @disposed
      begin
        assert_cursor(frame.cursor, "frame")
        expected = @cursor + 1
        unless frame.cursor == expected
          raise Exception.new("Replicated state source cursor has a gap: expected #{expected}, received #{frame.cursor}")
        end
        @cursor = frame.cursor
        @publisher.publish(frame.value, frame.context)
      rescue error
        fail(error)
      end
    end

    private def fail(error : Exception) : Nil
      return if @disposed
      @disposed = true
      begin
        @attachment.dispose
      rescue ex
        report(AggregateError.new([error, ex], "Replicated state source contract failed"))
        return
      end
      report(error)
    end

    private def report(error : Exception) : Nil
      @on_error.call(error)
    rescue ex
      REPORT_ASYNC.call(ex)
    end

    private def assert_cursor(cursor : Int64, kind : String) : Nil
      unless -MAX_SAFE_CURSOR <= cursor <= MAX_SAFE_CURSOR
        raise ArgumentError.new("Replicated state source #{kind} cursor must be a safe integer")
      end
    end
  end

  def self.replicated_state(initial : JSON::Any) : MutableReplicatedState
    MutableReplicatedState.new(initial)
  end

  def self.replicated_state(source : ReplicatedStateSource, on_error : ErrorReporter? = nil) : AttachedReplicatedState
    AttachedReplicatedState.attach(source, on_error)
  end
end
