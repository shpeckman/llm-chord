# src/llm/chord/delta/codec.cr
module LLM::Chord::Delta
  class Encoder
    def initialize
      @seen = Set(String).new
      @ids = {} of String => Int32
      @next_id = 0
      @previous : String? = nil
    end

    def encode(ops : Array(Op)) : Array(JSON::Any)
      @previous = nil
      result = [] of JSON::Any
      ops.each do |op|
        if op.is_a?(Op::Replace)
          result << arr([s("r"), op.value])
          @seen.clear
          @ids.clear
          @next_id = 0
          @previous = nil
          next
        end
        path = op_path(op)
        key = path.to_json
        if key == @previous
          result << short_wire(op)
          next
        end
        ref = intern(path, key, result)
        result << full_wire(op, ref)
        @previous = key
      end
      result
    end

    private def op_path(op : Op) : Path
      case op
      when Op::Set then op.path
      when Op::Delete then op.path
      when Op::Append then op.path
      when Op::Truncate then op.path
      when Op::Splice then op.path
      when Op::Move then op.path
      else raise ArgumentError.new("replace op has no path")
      end
    end

    private def intern(path : Path, key : String, result : Array(JSON::Any)) : Path | Int32
      if id = @ids[key]?
        return id
      elsif @seen.includes?(key)
        id = @next_id
        @next_id += 1
        @ids[key] = id
        result << arr([s("#"), i(id), path_wire(path)])
        return id
      else
        @seen.add(key)
        return path
      end
    end

    private def full_wire(op : Op, ref : Path | Int32) : JSON::Any
      case op
      when Op::Set then arr([s("s"), ref_wire(ref), op.value])
      when Op::Delete then arr([s("d"), ref_wire(ref)])
      when Op::Append then arr([s("a"), ref_wire(ref), s(op.text)])
      when Op::Truncate then arr([s("t"), ref_wire(ref), i(op.count)])
      when Op::Splice then arr([s("p"), ref_wire(ref), i(op.index), i(op.remove), items_wire(op.items)])
      when Op::Move then arr([s("m"), ref_wire(ref), perm_wire(op.permutation)])
      else raise ArgumentError.new("replace op has no path")
      end
    end

    private def short_wire(op : Op) : JSON::Any
      case op
      when Op::Set then arr([s("s"), op.value])
      when Op::Delete then arr([s("d")])
      when Op::Append then arr([s("a"), s(op.text)])
      when Op::Truncate then arr([s("t"), i(op.count)])
      when Op::Splice then arr([s("p"), i(op.index), i(op.remove), items_wire(op.items)])
      when Op::Move then arr([s("m"), perm_wire(op.permutation)])
      else raise ArgumentError.new("replace op has no path")
      end
    end

    private def ref_wire(ref : Path | Int32) : JSON::Any
      ref.is_a?(Int32) ? i(ref) : path_wire(ref)
    end

    private def path_wire(path : Path) : JSON::Any
      arr(path.map { |seg| seg.is_a?(String) ? s(seg) : i(seg) })
    end

    private def items_wire(items : Array(JSON::Any)) : JSON::Any
      arr(items)
    end

    private def perm_wire(perm : Array(Int32)) : JSON::Any
      arr(perm.map { |value| i(value) })
    end

    private def s(value : String) : JSON::Any
      JSON::Any.new(value)
    end

    private def i(value : Int32) : JSON::Any
      JSON::Any.new(value.to_i64)
    end

    private def arr(values : Array(JSON::Any)) : JSON::Any
      JSON::Any.new(values)
    end
  end

  class Decoder
    def initialize
      @paths = {} of Int32 => Path
      @previous = [] of Seg
      @has_previous = false
    end

    def decode(wire : Array(JSON::Any)) : Array(Op)
      @previous = [] of Seg
      @has_previous = false
      result = [] of Op
      wire.each do |op_any|
        arr = op_any.raw
        raise ArgumentError.new("op is not a tuple") unless arr.is_a?(Array) && !arr.empty?
        case arr[0].as_s
        when "#"
          raise ArgumentError.new("# shape") unless arr.size == 3
          id = int(arr[1])
          path = parse_path(arr[2])
          assert_safe_path(path)
          @paths[id] = path
        when "r"
          raise ArgumentError.new("r arity") unless arr.size == 2
          result << Op::Replace.new(arr[1])
          @paths.clear
          @has_previous = false
        else
          result << decode_op(arr)
        end
      end
      result
    end

    private def decode_op(arr : Array(JSON::Any)) : Op
      verb = arr[0].as_s
      short = (verb == "d" && arr.size == 1) ||
              (verb != "d" && verb != "p" && arr.size == 2) ||
              (verb == "p" && arr.size == 4)
      path : Path
      if short
        raise PathError.new([] of Seg) unless @has_previous
        path = @previous
      else
        ref = arr[1]
        if ref.raw.is_a?(Int64)
          id = ref.raw.as(Int64).to_i32
          resolved = @paths[id]?
          raise PathError.new(id.to_i64) if resolved.nil?
          path = resolved
        else
          path = parse_path(ref)
        end
        @previous = path
        @has_previous = true
      end
      raise PathError.new(path) if verb != "p" && verb != "m" && path.empty?
      case verb
      when "s"
        Op::Set.new(path, short ? arr[1] : arr[2])
      when "d"
        Op::Delete.new(path)
      when "a"
        Op::Append.new(path, (short ? arr[1] : arr[2]).as_s)
      when "t"
        Op::Truncate.new(path, int(short ? arr[1] : arr[2]))
      when "p"
        if short
          Op::Splice.new(path, int(arr[1]), int(arr[2]), arr[3].raw.as(Array(JSON::Any)))
        else
          Op::Splice.new(path, int(arr[2]), int(arr[3]), arr[4].raw.as(Array(JSON::Any)))
        end
      when "m"
        perm = (short ? arr[1] : arr[2]).raw.as(Array(JSON::Any)).map { |value| int(value) }
        Op::Move.new(path, perm)
      else
        raise ArgumentError.new("unknown op verb: #{verb}")
      end
    end

    private def parse_path(value : JSON::Any) : Path
      raw = value.raw
      raise ArgumentError.new("path is not an array") unless raw.is_a?(Array)
      raw.map do |seg_any|
        case raw_seg = seg_any.raw
        when String then raw_seg
        when Int64 then raw_seg.to_i32
        else raise ArgumentError.new("bad path segment")
        end
      end
    end

    private def int(value : JSON::Any) : Int32
      raw = value.raw
      raise ArgumentError.new("expected integer") unless raw.is_a?(Int64)
      raw.to_i32
    end
  end
end
