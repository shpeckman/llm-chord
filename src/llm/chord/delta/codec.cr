# src/llm/chord/delta/codec.cr
module LLM::Chord::Delta
  class Encoder
    def initialize
      @seen = ::Set(String).new
      @ids = {} of String => Int32
      @next_id = 0
    end

    def encode(ops : Enumerable(Op)) : Array(WireOp)
      previous = nil.as(String?)
      result = [] of WireOp
      ops.each do |op|
        case op
        when Op::Replace
          result << op.to_tuple
          @seen.clear
          @ids.clear
          @next_id = 0
          previous = nil
        when Op::Targeted
          key = op.path.to_json
          verb = JSON::Any.new(op.verb.to_s)
          if key == previous
            result << JSON::Any.new([verb] + op.arguments)
            next
          end
          result << JSON::Any.new([verb, reference(op.path, key, result)] + op.arguments)
          previous = key
        end
      end
      result
    end

    private def reference(path : Path, key : String, result : Array(WireOp)) : JSON::Any
      if id = @ids[key]?
        JSON::Any.new(id.to_i64)
      elsif @seen.includes?(key)
        id = @next_id
        @next_id += 1
        @ids[key] = id
        result << JSON::Any.new([JSON::Any.new("#"), JSON::Any.new(id.to_i64), Delta.path_to_json(path)])
        JSON::Any.new(id.to_i64)
      else
        @seen.add(key)
        Delta.path_to_json(path)
      end
    end
  end

  class Decoder
    def initialize
      @paths = {} of Int32 => Path
    end

    def decode(wire : Enumerable(WireOp)) : Array(Op)
      previous = nil.as(Path?)
      result = [] of Op
      wire.each do |op|
        Delta.assert_valid_wire_op(op)
        items = op.as_a
        case verb = items[0].as_s
        when "#"
          @paths[Delta.count_from_json(items[1], "# shape")] = Delta.path_from_json(items[2])
        when "r"
          result << Op::Replace.new(items[1])
          @paths.clear
          previous = nil
        else
          short = (verb == "d" && items.size == 1) ||
                  (verb != "d" && verb != "p" && items.size == 2) ||
                  (verb == "p" && items.size == 4)
          path = if short
                   previous || raise PathError.new([] of Seg)
                 else
                   resolved = resolve(items[1])
                   previous = resolved
                   resolved
                 end
          raise PathError.new(path) if verb != "p" && verb != "m" && path.empty?
          arguments = short ? items[1..] : items[2..]
          result << build(verb, path, arguments)
        end
      end
      result
    end

    private def resolve(ref : JSON::Any) : Path
      case ref.raw
      when Int64, Float64
        id = Delta.count_from_json(ref, "bad path id")
        @paths[id]? || raise PathError.new(id.to_i64)
      else
        Delta.path_from_json(ref)
      end
    end

    private def build(verb : String, path : Path, arguments : Array(JSON::Any)) : Op
      case verb
      when "s"
        Op::Set.new(path, arguments[0])
      when "d"
        Op::Delete.new(path)
      when "a"
        Op::Append.new(path, arguments[0].as_s)
      when "t"
        Op::Truncate.new(path, Delta.count_from_json(arguments[0], "t count"))
      when "p"
        Op::Splice.new(path, Delta.count_from_json(arguments[0], "p index"),
          Delta.count_from_json(arguments[1], "p remove"), arguments[2].as_a)
      when "m"
        Op::Move.new(path, Delta.permutation_from_json(arguments[0]))
      else
        raise ArgumentError.new("unknown op verb: #{verb}")
      end
    end
  end
end
