# src/llm/chord/delta/draft.cr
module LLM::Chord::Delta
  struct Draft
    getter value : JSON::Any

    def initialize(@value : JSON::Any); end

    def [](key : String) : Draft
      raw = @value.raw
      raise Exception.new("Draft is not an object") unless raw.is_a?(Hash)
      Draft.new(raw[key]? || JSON::Any.new(nil))
    end

    def []?(key : String) : Draft?
      raw = @value.raw
      if raw.is_a?(Hash)
        child = raw[key]?
        child ? Draft.new(child) : nil
      end
    end

    def [](index : Int) : Draft
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      Draft.new(raw[index])
    end

    def []=(key : String, value) : Nil
      raw = @value.raw
      raise Exception.new("Draft is not an object") unless raw.is_a?(Hash)
      raw[key] = Json.to_any(value)
    end

    def []=(index : Int, value) : Nil
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw[index] = Json.to_any(value)
    end

    def <<(value) : Nil
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw << Json.to_any(value)
    end

    def push(*values) : Int32
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      values.each { |value| raw << Json.to_any(value) }
      raw.size
    end

    def pop : JSON::Any?
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.pop?
    end

    def shift : JSON::Any?
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.shift?
    end

    def unshift(*values) : Int32
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      items = [] of JSON::Any
      values.each { |value| items << Json.to_any(value) }
      raw[0, 0] = items
      raw.size
    end

    def splice(index : Int, remove : Int, *items) : Array(JSON::Any)
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      removed = raw[index, remove]
      converted = [] of JSON::Any
      items.each { |item| converted << Json.to_any(item) }
      raw[index, remove] = converted
      removed
    end

    def delete_at(index : Int) : JSON::Any
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.delete_at(index)
    end

    def delete(key : String) : Nil
      raw = @value.raw
      raise Exception.new("Draft is not an object") unless raw.is_a?(Hash)
      raw.delete(key)
    end

    def size : Int32
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.size
    end

    def empty? : Bool
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.empty?
    end

    def reverse! : Draft
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.reverse!
      self
    end

    def sort! : Draft
      sort! { |a, b| a.to_json <=> b.to_json }
    end

    def sort!(&block : JSON::Any, JSON::Any -> Int32) : Draft
      raw = @value.raw
      raise Exception.new("Draft is not an array") unless raw.is_a?(Array)
      raw.sort! { |a, b| block.call(a, b) }
      self
    end

    def as_s : String
      @value.as_s
    end

    def as_i : Int64
      @value.raw.as(Int64)
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

    def string?(key : String) : String?
      raw = @value.raw
      return nil unless raw.is_a?(Hash)
      child = raw[key]?
      return nil if child.nil?
      child.raw.as?(String)
    end

    def int(key : String) : Int64
      value = child_value(key)
      raise Exception.new("Draft value is not an integer") unless value.is_a?(Int64)
      value
    end

    def float(key : String) : Float64
      value = child_value(key)
      raise Exception.new("Draft value is not a float") unless value.is_a?(Float64)
      value
    end

    def bool(key : String) : Bool
      value = child_value(key)
      raise Exception.new("Draft value is not a bool") unless value.is_a?(Bool)
      value
    end

    def array(key : String) : Array(JSON::Any)
      value = child_value(key)
      raise Exception.new("Draft value is not an array") unless value.is_a?(Array)
      value
    end

    def object(key : String) : Hash(String, JSON::Any)
      value = child_value(key)
      raise Exception.new("Draft value is not an object") unless value.is_a?(Hash)
      value
    end

    private def child_value(key : String) : JSON::Any::Type
      raw = @value.raw
      raise Exception.new("Draft is not an object") unless raw.is_a?(Hash)
      child = raw[key]?
      raise Exception.new("Draft key is missing: #{key}") if child.nil?
      child.raw
    end
  end
end
