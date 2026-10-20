# src/llm/chord/delta/utf16.cr
module LLM::Chord::Delta
  module Utf16
    def self.size(s : String) : Int32
      units = 0
      s.each_char { |char| units += char.ord >= 0x10000 ? 2 : 1 }
      units
    end

    def self.chars_for_units(s : String, units : Int32) : Int32
      remaining = units
      count = 0
      s.each_char do |char|
        break if remaining <= 0
        remaining -= char.ord >= 0x10000 ? 2 : 1
        count += 1
      end
      count
    end

    def self.slice(s : String, from_units : Int32) : String
      units = 0
      s.each_char_with_index do |char, index|
        return s[index, s.size - index] if units >= from_units
        units += char.ord >= 0x10000 ? 2 : 1
      end
      ""
    end
  end
end
