# src/llm/chord/state.cr
module LLM::Chord
  enum DeliveryKind
    Hydrate
    Update
  end

  struct Delivery
    getter kind : DeliveryKind
    getter sequence : Int32

    def initialize(@kind : DeliveryKind, @sequence : Int32); end
  end

  alias StateListener = Proc(JSON::Any, Delivery, Nil)

  private struct Publication
    getter value : JSON::Any
    getter sequence : Int32

    def initialize(@value : JSON::Any, @sequence : Int32); end
  end

  private struct Frame
    getter value : JSON::Any
    getter delivery : Delivery

    def initialize(@value : JSON::Any, @delivery : Delivery); end
  end

  private class Subscriber
    @pending = Deque(Frame).new

    def initialize(@listener : StateListener, @hydrated_sequence : Int32, @on_error : Proc(Exception, Nil))
      @running = false
      @started = false
      @closed = false
    end

    def push(frame : Frame) : Nil
      return if @closed
      if @pending.size >= 100
        hydration = @started ? nil : @pending.first?
        @pending.clear
        @pending << hydration if hydration
      end
      @pending << frame
    end

    def drain : Nil
      return if @running || @closed
      @running = true
      while frame = @pending.shift?
        @started = true
        begin
          @listener.call(frame.value, frame.delivery)
        rescue ex
          @on_error.call(ex)
        end
      end
      @running = false
    end

    def close : Nil
      @closed = true
      @pending.clear
    end

    def hydrated_sequence : Int32
      @hydrated_sequence
    end
  end

  private class AsyncSubscriber
    @channel = Channel(Frame).new(100)

    def initialize(@listener : StateListener, @hydrated_sequence : Int32, @on_error : Proc(Exception, Nil))
      @closed = false
      spawn { delivery_loop }
    end

    def push(frame : Frame) : Nil
      return if @closed
      @channel.send(frame)
    end

    def drain : Nil
    end

    def close : Nil
      return if @closed
      @closed = true
      @channel.close
    end

    def hydrated_sequence : Int32
      @hydrated_sequence
    end

    private def delivery_loop : Nil
      loop do
        frame = @channel.receive?
        break if frame.nil? || @closed
        begin
          @listener.call(frame.value, frame.delivery)
        rescue ex
          @on_error.call(ex)
        end
      end
    end
  end

  private class Publisher
    def initialize(@value : JSON::Any, @on_error : Proc(Exception, Nil), @async : Bool = false)
      @sequence = 0
      @subscribers = [] of (Subscriber | AsyncSubscriber)
      @publications = Deque(Publication).new
      @delivering = false
    end

    def value : JSON::Any
      @value
    end

    def subscribe(listener : StateListener) : Proc(Nil)
      subscriber = @async ? AsyncSubscriber.new(listener, @sequence, @on_error) : Subscriber.new(listener, @sequence, @on_error)
      @subscribers << subscriber
      subscriber.push(Frame.new(@value, Delivery.new(DeliveryKind::Hydrate, @sequence)))
      subscriber.drain
      -> { subscriber.close; @subscribers.delete(subscriber) }
    end

    def publish(value : JSON::Any) : Nil
      @value = value
      @sequence += 1
      @publications << Publication.new(value, @sequence)
      return if @delivering
      @delivering = true
      begin
        while publication = @publications.shift?
          delivery = Delivery.new(DeliveryKind::Update, publication.sequence)
          @subscribers.each do |subscriber|
            next if publication.sequence <= subscriber.hydrated_sequence
            subscriber.push(Frame.new(publication.value, delivery))
            subscriber.drain
          end
        end
      ensure
        @delivering = false
      end
    end
  end

  class ReplicatedState
    def initialize(@publisher : Publisher); end

    def value : JSON::Any
      @publisher.value
    end

    def subscribe(&listener : JSON::Any, Delivery -> Nil) : Proc(Nil)
      @publisher.subscribe(StateListener.new { |value, delivery| listener.call(value, delivery) })
    end
  end

  class MutableReplicatedState < ReplicatedState
    def initialize(initial : JSON::Any, @on_error : Proc(Exception, Nil), async : Bool = false)
      @tracker = Delta.track(initial)
      @changing = false
      super(Publisher.new(@tracker.value, @on_error, async))
    end

    def change(&mutate : Delta::Draft -> Nil) : Nil
      raise Exception.new("Replicated state cannot be changed reentrantly") if @changing
      @changing = true
      begin
        change = @tracker.begin_change
        prepared = begin
          mutate.call(change.state)
          change.prepare
        rescue ex
          change.abort
          raise ex
        end
        @tracker.adopt(prepared)
        @publisher.publish(prepared.value) unless prepared.ops.empty?
      ensure
        @changing = false
      end
    end

    def replace(value : JSON::Any) : Nil
      raise Exception.new("Replicated state cannot be replaced reentrantly") if @changing
      prepared = @tracker.prepare_replace(value)
      @tracker.adopt(prepared)
      @publisher.publish(prepared.value) unless prepared.ops.empty?
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

    def initialize(@cursor : Int64, @value : JSON::Any); end
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
    def self.attach(source : ReplicatedStateSource, on_error : Proc(Exception, Nil)) : AttachedReplicatedState
      attachment = source.attach
      state = new(attachment, on_error)
      state.activate
      state
    end

    def initialize(@attachment : ReplicatedStateSourceAttachment, @on_error : Proc(Exception, Nil))
      snapshot = @attachment.snapshot
      @cursor = snapshot.cursor
      @disposed = false
      super(Publisher.new(snapshot.value, @on_error))
    end

    def activate : Nil
      @attachment.activate do |frame|
        receive(frame)
      end
    end

    def dispose : Nil
      return if @disposed
      @disposed = true
      @attachment.dispose
    end

    private def receive(frame : SourceFrame) : Nil
      return if @disposed
      begin
        expected = @cursor + 1
        if frame.cursor != expected
          raise Exception.new("Replicated state source cursor has a gap: expected #{expected}, received #{frame.cursor}")
        end
        @cursor = frame.cursor
        @publisher.publish(frame.value)
      rescue ex
        fail(ex)
      end
    end

    private def fail(error : Exception) : Nil
      return if @disposed
      @disposed = true
      @attachment.dispose rescue nil
      @on_error.call(error)
    end
  end

  RAISE_ON_ERROR = Proc(Exception, Nil).new { |ex| raise ex }

  def self.replicated_state(initial : JSON::Any, on_error : Proc(Exception, Nil)? = nil) : MutableReplicatedState
    MutableReplicatedState.new(initial, on_error || RAISE_ON_ERROR)
  end

  def self.replicated_state(source : ReplicatedStateSource, on_error : Proc(Exception, Nil)? = nil) : AttachedReplicatedState
    AttachedReplicatedState.attach(source, on_error || RAISE_ON_ERROR)
  end
end
