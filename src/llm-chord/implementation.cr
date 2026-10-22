# src/llm-chord/implementation.cr
module LLM::Chord
  alias MethodFn = Proc(JSON::Any?, Ctx, JSON::Any?)

  abstract class OpaqueValue
  end

  class OpaqueBox(T) < OpaqueValue
    getter value : T

    def initialize(@value : T); end
  end

  alias MemberValue = MethodFn | Readable | Exposed | OpaqueValue

  class Implementation
    property variant : String?
    getter members : Hash(String, MemberValue)

    def initialize(@variant : String? = nil, @members : Hash(String, MemberValue) = {} of String => MemberValue); end

    def method(name : String, &block : JSON::Any?, Ctx -> T) : self forall T
      @members[name] = Implementation.method_fn(block)
      self
    end

    def state(name : String, source : Readable) : self
      @members[name] = source
      self
    end

    def expose(name : String, exposed : Exposed) : self
      @members[name] = exposed
      self
    end

    def opaque(name : String, value : T) : self forall T
      @members[name] = OpaqueBox(T).new(value)
      self
    end

    def [](name : String) : MemberValue
      @members[name]
    end

    def []?(name : String) : MemberValue?
      @members[name]?
    end

    def []=(name : String, value : MemberValue) : MemberValue
      @members[name] = value
    end

    def delete(name : String) : MemberValue?
      @members.delete(name)
    end

    def has_key?(name : String) : Bool
      @members.has_key?(name)
    end

    def keys : Array(String)
      @members.keys
    end

    def dup : Implementation
      Implementation.new(@variant, @members.dup)
    end

    protected def self.method_fn(block : Proc(JSON::Any?, Ctx, T)) : MethodFn forall T
      ->(args : JSON::Any?, ctx : Ctx) : JSON::Any? { Implementation.result(block.call(args, ctx)) }
    end

    protected def self.result(_value : Nil) : JSON::Any?
      nil
    end

    protected def self.result(value) : JSON::Any?
      Chord.json_value(value)
    end
  end
end
