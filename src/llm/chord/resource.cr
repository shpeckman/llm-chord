# src/llm/chord/resource.cr
module LLM::Chord
  enum ResourceState
    Closed
    Opening
    Open
    Unavailable
  end

  alias ResourceDep = Ref | AnyResource

  abstract class AnyResource
    getter key : String
    property version : Int32
    property? exclusive : Bool
    getter deps : Array(ResourceDep)
    getter state = ResourceState::Closed

    def initialize(@key : String, @version : Int32, @exclusive : Bool, @deps : Array(ResourceDep), @host : Host); end

    abstract def open(signal : AbortSignal, order : Array(AnyResource)) : Nil
    abstract def close(order : Array(AnyResource)) : Nil
    abstract def subscribable : Subscribable
  end

  class Resource(T) < AnyResource
    @value : T? = nil

    def initialize(key : String, version : Int32, exclusive : Bool, deps : Array(ResourceDep), host : Host,
                   @opener : Proc(AbortSignal, T), @closer : Proc(T, Nil)?)
      super(key, version, exclusive, deps, host)
    end

    def value : T
      raise Chord.not_ready("resource #{key} (inside a factory)") if @host.in_factory > 0
      open_value
    end

    def open_value : T
      raise ChordError.new(ErrorCode::Unavailable, "resource #{key} could not be restored") if @state.unavailable?
      raise Chord.not_ready("resource #{key}") unless @state.open?
      @value.as(T)
    end

    def mark_unavailable : Nil
      @state = ResourceState::Unavailable
      @value = nil
    end

    def open(signal : AbortSignal, order : Array(AnyResource)) : Nil
      return unless @state.closed?
      @state = ResourceState::Opening
      opened = begin
        @opener.call(signal)
      rescue error
        @state = ResourceState::Closed
        raise error
      end
      if signal.aborted?
        @state = ResourceState::Closed
        @closer.try &.call(opened)
        raise ChordError.new(ErrorCode::Aborted, "resource #{key} opened after abort")
      end
      @value = opened
      @state = ResourceState::Open
      order << self
    end

    def adopt(version : Int32, exclusive : Bool, opener : Proc(AbortSignal, T), closer : Proc(T, Nil)?) : Nil
      @version = version
      @exclusive = exclusive
      @opener = opener
      @closer = closer
    end

    def close(order : Array(AnyResource)) : Nil
      return unless @state.open?
      @state = ResourceState::Closed
      order.delete(self)
      closing = @value.as(T)
      @value = nil
      @closer.try &.call(closing)
    end

    def subscribable : Subscribable
      current = open_value
      current.as?(Subscribable) || raise Chord.invalid("implementation", "resource #{key}: its value has no subscribe()")
    end
  end

  class Exposed
    getter resource : AnyResource

    def initialize(@resource : AnyResource); end
  end
end
