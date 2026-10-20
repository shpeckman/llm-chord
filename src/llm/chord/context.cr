# src/llm/chord/context.cr
module LLM::Chord
  abstract class AnyContextKey
    getter description : String

    def initialize(@description : String = "anonymous"); end
  end

  class ContextKey(T) < AnyContextKey
  end

  abstract class Context
    BACKGROUND = EmptyContext.new("[Context BACKGROUND_CONTEXT]")
    TODO       = EmptyContext.new("[Context TODO_CONTEXT]")

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
