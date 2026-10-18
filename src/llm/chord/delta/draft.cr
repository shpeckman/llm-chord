# src/llm/chord/delta/draft.cr
module LLM::Chord::Delta
  struct Draft
    getter value : JSON::Any

    def initialize(@value : JSON::Any); end

    def [](key : String) : Draft
      raw = @value.raw
      raise TypeError.new("Draft is not an object") unless raw.is_a?(Hash)
      Draft.new(raw[key]? || JSON::Any.new(nil))
    end

    def []?(key : String) : Draft?
      raw = @value.raw
      return nil unless raw.is_a?(Hash)
      child = raw[key]?
      child ? Draft.new(child) : nil
    end

    def [](index : Int) : Draft
      raw = @value.raw
      raise TypeError.new("Draft is not an array") unless raw.is_a?(Array)
      Draft.new(raw[index])
    end

    def []=(key : String, value) : Nil
      raw = @value.raw
      raise TypeError.new("Draft is not an object") unless raw.is_a?(Hash)
      raw[key] = Json.to_any(value)
    end

    def []=(index : Int, value) : Nil
      raw = @value.raw
      raise TypeError.new("Draft is not an array") unless raw.is_a?(Array)
      raw[index] = Json.to_any(value)
    end

    def <<(value) : Nil
      raw = @value.raw
      raise TypeError.new("Draft is not an array") unless raw.is_a?(Array)
      raw << Json.to_any(value)
    end

    def as_s : String
      @value.as_s
    end

    def as_i : Int64
      @value.as_i
    end

    def as_f : Float64
      @value.as_f
    end

    def as_bool : Bool
      @value.as_bool
    end

    def as_a : Array(JSON::Any)
      @value.as_a
    end

    def as_h : Hash(String, JSON::Any)
      @value.as_h
    end

    def null? : Bool
      @value.raw.nil?
    end
  end
end
