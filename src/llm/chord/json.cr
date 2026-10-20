# src/llm/chord/json.cr
require "json"

module LLM::Chord::Json
  def self.deep_copy(value : JSON::Any) : JSON::Any
    case raw = value.raw
    when Hash
      result = Hash(String, JSON::Any).new(initial_capacity: raw.size)
      raw.each { |key, child| result[key] = deep_copy(child) }
      JSON::Any.new(result)
    when Array
      result = Array(JSON::Any).new(raw.size)
      raw.each { |child| result << deep_copy(child) }
      JSON::Any.new(result)
    else
      JSON::Any.new(raw)
    end
  end

  def self.copy_json(value : JSON::Any) : JSON::Any
    case raw = value.raw
    when Float64
      raise ArgumentError.new("Value contains a non-finite number and is not strict JSON") unless raw.finite?
      value
    when Hash
      result = Hash(String, JSON::Any).new(initial_capacity: raw.size)
      raw.each { |key, child| result[key] = copy_json(child) }
      JSON::Any.new(result)
    when Array
      result = Array(JSON::Any).new(raw.size)
      raw.each { |child| result << copy_json(child) }
      JSON::Any.new(result)
    else
      JSON::Any.new(raw)
    end
  end

  def self.container?(value : JSON::Any) : Bool
    raw = value.raw
    raw.is_a?(Hash) || raw.is_a?(Array)
  end

  def self.identical?(left : JSON::Any, right : JSON::Any) : Bool
    a = left.raw
    b = right.raw
    case a
    when Hash
      b.is_a?(Hash) && a.same?(b)
    when Array
      b.is_a?(Array) && a.same?(b)
    else
      !b.is_a?(Hash) && !b.is_a?(Array) && a == b
    end
  end

  def self.equal?(left : JSON::Any, right : JSON::Any) : Bool
    return true if identical?(left, right)
    a = left.raw
    b = right.raw
    if a.is_a?(Hash) && b.is_a?(Hash)
      return false unless a.size == b.size
      a.each do |key, child|
        other = b[key]?
        return false if other.nil? || !equal?(child, other)
      end
      true
    elsif a.is_a?(Array) && b.is_a?(Array)
      return false unless a.size == b.size
      a.each_with_index { |child, index| return false unless equal?(child, b[index]) }
      true
    else
      false
    end
  end

  def self.number_text(value : Int64 | Float64) : String
    if value.is_a?(Float64) && value == value.trunc && value.abs < 1e21
      value.to_i64.to_s
    else
      value.to_s
    end
  end

  def self.js_string(value : JSON::Any) : String
    case raw = value.raw
    when Nil            then "null"
    when String         then raw
    when Int64, Float64 then number_text(raw)
    when Bool           then raw.to_s
    when Array          then raw.join(',') { |item| item.raw.nil? ? "" : js_string(item) }
    else                     "[object Object]"
    end
  end

  def self.to_any(value) : JSON::Any
    case value
    when JSON::Any
      copy_json(value)
    else
      begin
        JSON.parse(value.to_json)
      rescue ex : JSON::Error
        raise ArgumentError.new("Value is not strict JSON: #{ex.message}")
      end
    end
  end

  def self.to_struct(t : T.class, value : JSON::Any) : T forall T
    T.from_json(value.to_json)
  end

  def self.from_struct(value) : JSON::Any
    JSON.parse(value.to_json)
  end

  def self.valid?(value : JSON::Any) : Bool
    case raw = value.raw
    when Float64
      raw.finite?
    when Hash
      raw.each_value.all? { |child| valid?(child) }
    when Array
      raw.all? { |child| valid?(child) }
    else
      true
    end
  end

  def self.strict?(value : JSON::Any) : Bool
    valid?(value)
  end

  def self.validate!(value : JSON::Any) : JSON::Any
    raise ArgumentError.new("Replicated state values must be strict JSON") unless valid?(value)
    value
  end
end
