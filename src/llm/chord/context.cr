# src/llm/chord/context.cr
module LLM::Chord
  class AbortError < Exception
    def initialize(message : String = "The operation was aborted")
      super(message)
    end
  end

  class AbortSignal
    getter reason : Exception? = nil
    getter? aborted = false
    @listeners = {} of Int32 => Proc(Exception, Nil)
    @next_listener = 0

    def self.any(signals : Enumerable(AbortSignal)) : AbortSignal
      combined = AbortSignal.new
      if aborted = signals.find(&.aborted?)
        combined.abort(aborted.reason.not_nil!)
        return combined
      end
      removals = [] of Proc(Nil)
      signals.each do |signal|
        remove = signal.on_abort do |reason|
          removals.each(&.call)
          combined.abort(reason)
        end
        removals << remove
      end
      combined
    end

    def on_abort(&listener : Exception -> Nil) : Proc(Nil)
      remover(@aborted ? nil : register(listener))
    end

    def throw_if_aborted : Nil
      if reason = @reason
        raise reason
      end
    end

    private def register(listener : Proc(Exception, Nil)) : Int32
      id = @next_listener
      @next_listener += 1
      @listeners[id] = listener
      id
    end

    private def remover(id : Int32?) : Proc(Nil)
      -> { id.try { |key| @listeners.delete(key) }; nil }
    end

    protected def abort(reason : Exception) : Nil
      return if @aborted
      @aborted = true
      @reason = reason
      listeners = @listeners.values
      @listeners.clear
      listeners.each do |listener|
        listener.call(reason)
      rescue error
        REPORT_ASYNC.call(error)
      end
    end
  end

  class AbortController
    getter signal = AbortSignal.new

    def abort(reason : Exception = AbortError.new) : Nil
      @signal.abort(reason)
    end

    def abort(message : String) : Nil
      abort(AbortError.new(message))
    end
  end

  abstract class AnyContextKey
    getter description : String

    def initialize(@description : String = "anonymous"); end
  end

  class ContextKey(T) < AnyContextKey
  end

  abstract class Context
    ABORT_SIGNAL_KEY = ContextKey(AbortSignal?).new("chord.abortSignal")
    TELEMETRY_KEY    = ContextKey(LLM::Telemetry::TelemetrySpan).new("chord.telemetry")
    BACKGROUND       = EmptyContext.new("[Context BACKGROUND_CONTEXT]")
    TODO             = EmptyContext.new("[Context TODO_CONTEXT]")

    def value(key : ContextKey(T)) : T? forall T
      context = self
      while context.is_a?(ValueContext)
        return Box(T).unbox(context.slot) if context.key.same?(key)
        context = context.parent
      end
      nil
    end

    def with_value(key : ContextKey(T), value : T) : Context forall T
      ValueContext.new(self, key, Box(T).box(value))
    end

    def abort_signal : AbortSignal?
      value(ABORT_SIGNAL_KEY)
    end

    def telemetry : LLM::Telemetry::TelemetrySpan
      value(TELEMETRY_KEY) || LLM::Telemetry::NOOP
    end

    def with_telemetry(span : LLM::Telemetry::TelemetrySpan) : Context
      with_value(TELEMETRY_KEY, span)
    end

    def trace_in(options : LLM::Telemetry::SpanOptions, &)
      telemetry.start_span(options) { |span| yield with_telemetry(span) }
    end

    def trace_in(name : String, &)
      trace_in(LLM::Telemetry::SpanOptions.new(name)) { |context| yield context }
    end

    def with_abort_signal(signal : AbortSignal) : Context
      parent = abort_signal
      with_value(ABORT_SIGNAL_KEY, parent ? AbortSignal.any([parent, signal]) : signal)
    end

    def without_abort_signal : Context
      with_value(ABORT_SIGNAL_KEY, nil.as(AbortSignal?))
    end

    def with_cancel : Tuple(Context, AbortController)
      controller = AbortController.new
      {with_abort_signal(controller.signal), controller}
    end

    def await(channel : Channel(T)) : T forall T
      signal = abort_signal
      return channel.receive unless signal
      signal.throw_if_aborted
      aborted = Channel(Nil).new(1)
      remove = signal.on_abort do
        select
        when aborted.send(nil)
        else
        end
      end
      begin
        select
        when value = channel.receive
          value
        when aborted.receive
          raise signal.reason.not_nil!
        end
      ensure
        remove.call
      end
    end

    def await(&work : -> T) : T forall T
      results = [] of T
      failure = nil.as(Exception?)
      done = Channel(Nil).new(1)
      spawn do
        begin
          results << work.call
        rescue error
          failure = error
        end
        done.send(nil)
      end
      await(done)
      if error = failure
        raise error
      end
      results[0]
    end

    def to_s(io : IO) : Nil
      io << name
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    protected abstract def name : String
  end

  class EmptyContext < Context
    def initialize(@label : String); end

    protected def name : String
      @label
    end
  end

  class ValueContext < Context
    getter parent : Context
    getter key : AnyContextKey
    getter slot : Void*

    def initialize(@parent : Context, @key : AnyContextKey, @slot : Void*); end

    protected def name : String
      "#{@parent}.WithValue(#{@key.description})"
    end
  end
end
