# src/llm/chord/json.cr
require "json"

module LLM::Chord
  module Json
    def self.deep_copy(value : JSON::Any) : JSON::Any
      case raw = value.raw
      when Hash
        result = {} of String => JSON::Any
        raw.each { |key, child| result[key] = deep_copy(child) }
        JSON::Any.new(result)
      when Array
        result = [] of JSON::Any
        raw.each { |child| result << deep_copy(child) }
        JSON::Any.new(result)
      else
        JSON::Any.new(raw)
      end
    end

    def self.container?(value : JSON::Any) : Bool
      raw = value.raw
      raw.is_a?(Hash) || raw.is_a?(Array)
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
  end
end
