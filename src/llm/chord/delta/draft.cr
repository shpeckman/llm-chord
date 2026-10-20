# src/llm/chord/delta/draft.cr
module LLM::Chord::Delta
  class Draft
    def initialize(@overlay : Overlay, @value : JSON::Any, @parent : Draft?, @key : Seg?, @root : Bool = false); end

    def value : JSON::Any
      Json.deep_copy(current)
    end

    def [](key : String) : Draft
      child = read_hash[key]?
      child ? Draft.new(@overlay, child, self, key) : detach(JSON::Any.new(nil))
    end

    def []?(key : String) : Draft?
      raw = current.raw
      return unless raw.is_a?(Hash)
      child = raw[key]?
      Draft.new(@overlay, child, self, key) if child
    end

    def [](index : Int) : Draft
      self[index]? || raise IndexError.new
    end

    def []?(index : Int) : Draft?
      array = read_array
      position = index.to_i32
      Draft.new(@overlay, array[position], self, position) if 0 <= position < array.size
    end

    def []=(key : String, value) : Nil
      read_hash
      placed = @overlay.place(value)
      writable_hash[key] = placed
    end

    def []=(index : Int, value) : Nil
      size = read_array.size
      position = index.to_i32
      raise OverlayError.new("Only array indices and length can be written") if position < 0
      raise OverlayError.new("Overlay arrays cannot contain holes") if position > size
      placed = @overlay.place(value)
      target = writable_array
      position == target.size ? target << placed : (target[position] = placed)
    end

    def <<(value) : Draft
      push(value)
      self
    end

    def push(*values) : Int32
      size = read_array.size
      placed = place_all(values)
      return size if placed.empty?
      writable_array.concat(placed).size
    end

    def pop : Draft?
      return if read_array.empty?
      detach(writable_array.pop)
    end

    def shift : Draft?
      return if read_array.empty?
      detach(writable_array.shift)
    end

    def unshift(*values) : Int32
      size = read_array.size
      placed = place_all(values)
      return size if placed.empty?
      target = writable_array
      target[0, 0] = placed
      target.size
    end

    def splice(start : Int) : Array(Draft)
      splice(start, Int32::MAX)
    end

    def splice(start : Int, delete_count : Int, *items) : Array(Draft)
      length = read_array.size
      from = relative(start, length)
      count = delete_count.clamp(0, length - from).to_i32
      placed = place_all(items)
      return [] of Draft if count == 0 && placed.empty?
      target = writable_array
      removed = target[from, count]
      target[from, count] = placed
      removed.map { |item| detach(item) }
    end

    def delete_at(index : Int) : Draft
      position = index.to_i32
      raise IndexError.new unless 0 <= position < read_array.size
      detach(writable_array.delete_at(position))
    end

    def delete(key : String) : Draft?
      return unless read_hash.has_key?(key)
      writable_hash.delete(key).try { |removed| detach(removed) }
    end

    def size : Int32
      case raw = current.raw
      when Array then raw.size
      when Hash  then raw.size
      else            raise OverlayError.new("Draft is not a container")
      end
    end

    def size=(length : Int) : Int
      size = read_array.size
      raise OverlayError.new("Invalid array length") if length < 0
      return length if length == size
      target = writable_array
      if length > size
        (length - size).times { target << JSON::Any.new(nil) }
      else
        target.pop(size - length)
      end
      length
    end

    def empty? : Bool
      size == 0
    end

    def reverse! : Draft
      return self if read_array.size < 2
      writable_array.reverse!
      self
    end

    def sort! : Draft
      return self if read_array.size < 2
      target = writable_array
      keys = target.map { |item| Json.js_string(item).to_utf16 }
      order = (0...target.size).to_a.sort! do |left, right|
        compared = compare_units(keys[left], keys[right])
        compared == 0 ? left <=> right : compared
      end
      snapshot = target.dup
      target.replace(order.map { |index| snapshot[index] })
      self
    end

    def sort!(&block : Draft, Draft -> Int32) : Draft
      return self if read_array.size < 2
      target = writable_array
      handles = target.map_with_index { |item, index| Draft.new(@overlay, item, self, index) }
      sorted = handles.sort { |left, right| block.call(left, right) }
      target.replace(sorted.map(&.resolved))
      self
    end

    def fill(value, start : Int = 0, stop : Int? = nil) : Draft
      length = read_array.size
      from = relative(start, length)
      to = relative(stop || length, length)
      return self if from >= to
      placed = (from...to).map { @overlay.place(value) }
      target = writable_array
      placed.each_with_index { |item, offset| target[from + offset] = item }
      self
    end

    def copy_within(target_index : Int, start : Int, stop : Int? = nil) : Draft
      length = read_array.size
      to = relative(target_index, length)
      from = relative(start, length)
      final = relative(stop || length, length)
      count = Math.min(final - from, length - to)
      return self if count <= 0
      target = writable_array
      sources = (0...count).map { |offset| @overlay.place(target[from + offset]) }
      sources.each_with_index { |item, offset| target[to + offset] = item }
      self
    end

    def as_s : String
      current.as_s
    end

    def as_i : Int64
      current.raw.as(Int64)
    end

    def as_f : Float64
      current.as_f
    end

    def as_bool : Bool
      current.as_bool
    end

    def as_a : Array(Draft)
      read_array.map_with_index { |item, index| Draft.new(@overlay, item, self, index) }
    end

    def as_h : Hash(String, Draft)
      read_hash.each_with_object({} of String => Draft) do |(key, item), result|
        result[key] = Draft.new(@overlay, item, self, key)
      end
    end

    def null? : Bool
      current.raw.nil?
    end

    def string?(key : String) : String?
      raw = current.raw
      return unless raw.is_a?(Hash)
      raw[key]?.try(&.raw.as?(String))
    end

    def int(key : String) : Int64
      value = child_value(key)
      raise OverlayError.new("Draft value is not an integer") unless value.is_a?(Int64)
      value
    end

    def float(key : String) : Float64
      value = child_value(key)
      raise OverlayError.new("Draft value is not a float") unless value.is_a?(Float64)
      value
    end

    def bool(key : String) : Bool
      value = child_value(key)
      raise OverlayError.new("Draft value is not a bool") unless value.is_a?(Bool)
      value
    end

    def array(key : String) : Array(Draft)
      child = self[key]
      raise OverlayError.new("Draft value is not an array") unless child.resolved.raw.is_a?(Array)
      child.as_a
    end

    def object(key : String) : Hash(String, Draft)
      child = self[key]
      raise OverlayError.new("Draft value is not an object") unless child.resolved.raw.is_a?(Hash)
      child.as_h
    end

    protected def resolved : JSON::Any
      current
    end

    protected def writable_container : JSON::Any
      @overlay.assert_writable
      value = @overlay.latest(@root ? @overlay.root : @value)
      return value if @overlay.owned?(value)
      copy = @overlay.copy(value)
      if @root
        @overlay.root = copy
      elsif parent = @parent
        relink(parent.writable_container, value, copy)
      end
      @value = copy
      copy
    end

    private def current : JSON::Any
      @overlay.assert_readable
      @overlay.latest(@root ? @overlay.root : @value)
    end

    private def relink(container : JSON::Any, original : JSON::Any, copy : JSON::Any) : Nil
      case raw = container.raw
      when Hash
        key = @key.as?(String)
        if key && (slot = raw[key]?) && Json.identical?(slot, original)
          raw[key] = copy
        end
      when Array
        position = @key.as?(Int32)
        unless position && position < raw.size && Json.identical?(raw[position], original)
          position = raw.index { |item| Json.identical?(item, original) }
        end
        if position
          raw[position] = copy
          @key = position
        end
      end
    end

    private def place_all(values : Tuple) : Array(JSON::Any)
      placed = Array(JSON::Any).new(values.size)
      values.each { |value| placed << @overlay.place(value) }
      placed
    end

    private def detach(value : JSON::Any) : Draft
      Draft.new(@overlay, value, nil, nil)
    end

    private def read_hash : Hash(String, JSON::Any)
      current.raw.as?(Hash) || raise OverlayError.new("Draft is not an object")
    end

    private def read_array : Array(JSON::Any)
      current.raw.as?(Array) || raise OverlayError.new("Draft is not an array")
    end

    private def writable_hash : Hash(String, JSON::Any)
      writable_container.raw.as(Hash)
    end

    private def writable_array : Array(JSON::Any)
      writable_container.raw.as(Array)
    end

    private def child_value(key : String) : JSON::Any::Type
      child = read_hash[key]?
      raise OverlayError.new("Draft key is missing: #{key}") if child.nil?
      child.raw
    end

    private def relative(index : Int, length : Int32) : Int32
      index < 0 ? Math.max(length + index, 0).to_i32 : Math.min(index, length).to_i32
    end

    private def compare_units(left : Slice(UInt16), right : Slice(UInt16)) : Int32
      Math.min(left.size, right.size).times do |index|
        compared = left[index] <=> right[index]
        return compared unless compared == 0
      end
      left.size <=> right.size
    end
  end
end
