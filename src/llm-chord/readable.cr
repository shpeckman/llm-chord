# src/llm-chord/readable.cr
module LLM::Chord
  enum RefStatus
    Loading
    Live
    Released
    Gone

    def label : String
      to_s.downcase
    end
  end

  record Shape, variant : String?, members : Array(String), contract : String

  struct StateEvent
    enum Kind
      Snap
      Ops
      Reset
    end

    getter kind : Kind
    getter value : JSON::Any
    getter ops : Array(Delta::Op)

    def initialize(@kind : Kind, @value : JSON::Any, @ops : Array(Delta::Op) = [] of Delta::Op); end

    def self.snap(value : JSON::Any) : StateEvent
      new(Kind::Snap, value)
    end

    def self.ops(ops : Array(Delta::Op), value : JSON::Any) : StateEvent
      new(Kind::Ops, value, ops)
    end

    def self.reset(value : JSON::Any) : StateEvent
      new(Kind::Reset, value)
    end
  end

  module Subscribable
    abstract def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
  end

  abstract class Readable
    include Subscribable

    abstract def value : JSON::Any
    abstract def events(&listener : StateEvent -> Nil) : Proc(Nil)

    def hydrated? : Bool
      true
    end

    def wait_hydrated : Nil
    end
  end

  class Listeners(T)
    @entries = {} of Int32 => T
    @next = 0

    def add(listener : T) : Int32
      id = @next
      @next += 1
      @entries[id] = listener
      id
    end

    def delete(id : Int32) : Nil
      @entries.delete(id)
    end

    def includes?(id : Int32) : Bool
      @entries.has_key?(id)
    end

    def snapshot : Array(Tuple(Int32, T))
      @entries.to_a
    end

    def size : Int32
      @entries.size
    end

    def empty? : Bool
      @entries.empty?
    end

    def clear : Nil
      @entries.clear
    end

    def remover(id : Int32) : Proc(Nil)
      -> { @entries.delete(id); nil }
    end
  end

  def self.json_value(value : JSON::Any) : JSON::Any
    value
  end

  def self.json_value(value) : JSON::Any
    Json.to_any(value)
  end

  def self.json_input(_value : Nil) : JSON::Any?
    nil
  end

  def self.json_input(value) : JSON::Any?
    json_value(value)
  end

  def self.not_ready(what : String) : ChordError
    ChordError.new(ErrorCode::NotReady, "#{what} is not ready")
  end
end
