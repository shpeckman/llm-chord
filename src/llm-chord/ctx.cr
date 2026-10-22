# src/llm-chord/ctx.cr
module LLM::Chord
  class Ctx
    getter signal : AbortSignal
    getter root_id : String
    getter code_version : Int32
    getter principal : JSON::Any
    getter? holder : Bool
    getter? closed = false
    protected getter host : Host
    @refs = [] of Ref
    @release : Proc(Nil)
    @closing = AbortController.new

    def initialize(@host : Host, signals : Array(AbortSignal), @root_id : String, @code_version : Int32,
                   @principal : JSON::Any, @holder : Bool = false)
      linked = Ctx.linked_signal(signals)
      @signal = linked[0]
      @release = linked[1]
    end

    def get(type : Contract, input = nil, principal = nil, state : Bool = true) : Ref
      check(@host)
      ref = @host.acquire(type, input, principal.nil? ? @principal : Chord.json_value(principal), RefOwner::Call,
        state: state)
      @refs << ref
      Chord.await_ready(ref, [@signal, @closing.signal], @host.ready_timeout)
      ref
    end

    protected def check(host : Host) : Nil
      raise Chord.invalid("foreign_ctx", "ctx belongs to another host") unless @host.same?(host)
      raise ChordError.new(ErrorCode::Aborted, "ctx expired: its call already settled", reason: "expired") if @closed
      return unless @signal.aborted?
      reason = @signal.reason
      if reason.is_a?(ChordError) && reason.code.superseded?
        raise ChordError.new(ErrorCode::Superseded, reason.message || "superseded", cause: reason)
      end
      raise ChordError.new(ErrorCode::Aborted, "ctx aborted", cause: reason)
    end

    protected def child(object : ObjectImpl) : Ctx
      Ctx.new(@host, [@signal, object.call_abort.signal], @root_id, @code_version, @host.principal)
    end

    protected def close : Nil
      @closed = true
      @closing.abort(ChordError.new(ErrorCode::Aborted, "ctx expired: its call already settled", reason: "expired"))
      @release.call
      refs = @refs.dup
      @refs.clear
      refs.each(&.release)
    end

    protected def self.linked_signal(sources : Array(AbortSignal)) : Tuple(AbortSignal, Proc(Nil))
      controller = AbortController.new
      detach = [] of Proc(Nil)
      release = -> { detach.each(&.call); detach.clear; nil }
      sources.each do |source|
        if source.aborted?
          release.call
          controller.abort(source.reason.not_nil!)
          break
        end
        detach << source.on_abort do |reason|
          release.call
          controller.abort(reason)
        end
      end
      {controller.signal, release}
    end
  end

  def self.await_ready(ref : Ref, signals : Array(AbortSignal), timeout : Time::Span?) : Nil
    case ref.ready.wait(signals, timeout)
    in .settled?
      return unless failure = ref.ready.error
      ref.release
      raise failure
    in .aborted?
      ref.release
      raise ChordError.new(ErrorCode::Aborted, "call aborted", cause: signals.find(&.aborted?).try(&.reason))
    in .timed_out?
      ref.release
      raise ChordError.new(ErrorCode::Unavailable, "#{ref.address} was not ready after #{Chord.milliseconds(timeout)} ms",
        reason: "ready_timeout")
    end
  end

  def self.milliseconds(span : Time::Span?) : Int64
    span.try(&.total_milliseconds.to_i64) || 0_i64
  end
end
