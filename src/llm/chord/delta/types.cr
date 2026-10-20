# src/llm/chord/delta/types.cr
module LLM::Chord::Delta
  alias Seg = String | Int32
  alias Path = Array(Seg)
  alias WireOp = JSON::Any

  RESERVED_SEGMENTS = ["__proto__", "constructor", "prototype"]

  class UnsafePathError < Exception
    getter segment : JSON::Any

    def initialize(segment : Seg | Int64)
      @segment = JSON::Any.new(segment.is_a?(Int32) ? segment.to_i64 : segment)
      super("unsafe path segment: #{@segment}")
    end

    def initialize(@segment : JSON::Any)
      super("unsafe path segment: #{@segment}")
    end
  end

  class PathError < Exception
    getter path : Path | Int64

    def initialize(@path : Path | Int64)
      super("unresolvable path: #{@path.to_json}")
    end
  end

  abstract struct Op
    abstract def verb : Char
    abstract def to_tuple : JSON::Any

    def replace? : Bool
      false
    end

    def self.from_tuple(tuple : JSON::Any) : Op
      items = tuple.as_a? || raise ArgumentError.new("op is not a tuple")
      raise ArgumentError.new("op is not a tuple") if items.empty?
      case verb = items[0].as_s?
      when "r"
        raise ArgumentError.new("r arity") unless items.size == 2
        Replace.new(items[1])
      when "s"
        raise ArgumentError.new("s arity") unless items.size == 3
        Set.new(Delta.target_path_from_json(items[1]), items[2])
      when "d"
        raise ArgumentError.new("d arity") unless items.size == 2
        Delete.new(Delta.target_path_from_json(items[1]))
      when "a"
        text = items[2]?.try(&.as_s?)
        raise ArgumentError.new("a shape") unless items.size == 3 && text
        Append.new(Delta.target_path_from_json(items[1]), text)
      when "t"
        raise ArgumentError.new("t shape") unless items.size == 3
        count = Delta.count_from_json(items[2], "t shape")
        Truncate.new(Delta.target_path_from_json(items[1]), count)
      when "p"
        raise ArgumentError.new("p arity") unless items.size == 5
        path = Delta.path_from_json(items[1])
        index = Delta.count_from_json(items[2], "p index")
        remove = Delta.count_from_json(items[3], "p remove")
        inserted = items[4].as_a? || raise ArgumentError.new("p items")
        Splice.new(path, index, remove, inserted)
      when "m"
        raise ArgumentError.new("m arity") unless items.size == 3
        Move.new(Delta.path_from_json(items[1]), Delta.permutation_from_json(items[2]))
      else
        raise ArgumentError.new("unknown op verb: #{verb || items[0]}")
      end
    end

    struct Replace < Op
      getter value : JSON::Any

      def initialize(@value : JSON::Any); end

      def verb : Char
        'r'
      end

      def replace? : Bool
        true
      end

      def to_tuple : JSON::Any
        JSON::Any.new([JSON::Any.new("r"), @value])
      end
    end

    abstract struct Targeted < Op
      getter path : Path

      def initialize(@path : Path); end

      abstract def arguments : Array(JSON::Any)

      def to_tuple : JSON::Any
        JSON::Any.new([JSON::Any.new(verb.to_s), Delta.path_to_json(@path)] + arguments)
      end
    end

    struct Set < Targeted
      getter value : JSON::Any

      def initialize(path : Path, @value : JSON::Any)
        Delta.assert_target(path)
        super(path)
      end

      def verb : Char
        's'
      end

      def arguments : Array(JSON::Any)
        [@value]
      end
    end

    struct Delete < Targeted
      def initialize(path : Path)
        Delta.assert_target(path)
        super(path)
      end

      def verb : Char
        'd'
      end

      def arguments : Array(JSON::Any)
        [] of JSON::Any
      end
    end

    struct Append < Targeted
      getter text : String

      def initialize(path : Path, @text : String)
        Delta.assert_target(path)
        super(path)
      end

      def verb : Char
        'a'
      end

      def arguments : Array(JSON::Any)
        [JSON::Any.new(@text)]
      end
    end

    struct Truncate < Targeted
      getter count : Int32

      def initialize(path : Path, @count : Int32)
        Delta.assert_target(path)
        raise ArgumentError.new("t shape") if @count < 0
        super(path)
      end

      def verb : Char
        't'
      end

      def arguments : Array(JSON::Any)
        [JSON::Any.new(@count.to_i64)]
      end
    end

    struct Splice < Targeted
      getter index : Int32
      getter remove : Int32
      getter items : Array(JSON::Any)

      def initialize(path : Path, @index : Int32, @remove : Int32, @items : Array(JSON::Any))
        Delta.assert_safe_path(path)
        raise ArgumentError.new("p index") if @index < 0
        raise ArgumentError.new("p remove") if @remove < 0
        super(path)
      end

      def verb : Char
        'p'
      end

      def arguments : Array(JSON::Any)
        [JSON::Any.new(@index.to_i64), JSON::Any.new(@remove.to_i64), JSON::Any.new(@items)]
      end
    end

    struct Move < Targeted
      getter permutation : Array(Int32)

      def initialize(path : Path, @permutation : Array(Int32))
        Delta.assert_safe_path(path)
        Delta.assert_permutation(@permutation)
        super(path)
      end

      def verb : Char
        'm'
      end

      def arguments : Array(JSON::Any)
        [JSON::Any.new(@permutation.map { |index| JSON::Any.new(index.to_i64) })]
      end
    end
  end

  def self.base?(ops : Indexable(Op)) : Bool
    !ops.empty? && ops[0].replace?
  end

  def self.base?(wire : Indexable(JSON::Any)) : Bool
    !wire.empty? && wire[0].as_a?.try(&.first?.try(&.as_s?)) == "r"
  end

  def self.assert_safe_path(path : Path) : Nil
    path.each do |seg|
      if seg.is_a?(String)
        raise UnsafePathError.new(seg) if RESERVED_SEGMENTS.includes?(seg)
      elsif seg < 0
        raise UnsafePathError.new(seg)
      end
    end
  end

  def self.assert_target(path : Path) : Nil
    raise ArgumentError.new("path is empty") if path.empty?
    assert_safe_path(path)
  end

  def self.assert_permutation(permutation : Array(Int32)) : Nil
    seen = Slice(Bool).new(permutation.size, false)
    permutation.each do |index|
      if index < 0 || index >= permutation.size || seen[index]
        raise ArgumentError.new("m permutation is not a bijection")
      end
      seen[index] = true
    end
  end

  def self.assert_valid_wire_op(op : JSON::Any) : Nil
    items = op.as_a? || raise ArgumentError.new("op is not a tuple")
    raise ArgumentError.new("op is not a tuple") if items.empty?
    case verb = items[0].as_s?
    when "r"
      raise ArgumentError.new("r arity") unless items.size == 2
    when "s"
      if items.size == 3
        wire_ref(items[1])
      elsif items.size != 2
        raise ArgumentError.new("s arity")
      end
    when "d"
      if items.size == 2
        wire_ref(items[1])
      elsif items.size != 1
        raise ArgumentError.new("d arity")
      end
    when "a"
      case items.size
      when 3
        wire_ref(items[1])
        raise ArgumentError.new("a value") unless items[2].as_s?
      when 2
        raise ArgumentError.new("a value") unless items[1].as_s?
      else
        raise ArgumentError.new("a arity")
      end
    when "t"
      case items.size
      when 3
        wire_ref(items[1])
        count_from_json(items[2], "t count")
      when 2
        count_from_json(items[1], "t count")
      else
        raise ArgumentError.new("t arity")
      end
    when "p"
      raise ArgumentError.new("p arity") unless items.size == 4 || items.size == 5
      offset = items.size - 4
      wire_ref(items[1]) if offset == 1
      count_from_json(items[1 + offset], "p index")
      count_from_json(items[2 + offset], "p remove")
      raise ArgumentError.new("p items") unless items[3 + offset].as_a?
    when "m"
      if items.size == 3
        wire_ref(items[1])
      elsif items.size != 2
        raise ArgumentError.new("m arity")
      end
      assert_permutation(permutation_from_json(items[-1]))
    when "#"
      raise ArgumentError.new("# shape") unless items.size == 3 && items[2].as_a?
      count_from_json(items[1], "# shape")
      path_from_json(items[2])
    else
      raise ArgumentError.new("unknown op verb: #{verb || items[0]}")
    end
  end

  def self.path_to_json(path : Path) : JSON::Any
    JSON::Any.new(path.map { |seg| JSON::Any.new(seg.is_a?(Int32) ? seg.to_i64 : seg) })
  end

  def self.path_from_json(value : JSON::Any) : Path
    segments = value.as_a? || raise ArgumentError.new("path is not an array")
    segments.map do |segment|
      case raw = segment.raw
      when String
        raise UnsafePathError.new(raw) if RESERVED_SEGMENTS.includes?(raw)
        raw.as(Seg)
      when Int64
        raise UnsafePathError.new(raw) unless 0 <= raw <= Int32::MAX
        raw.to_i32.as(Seg)
      when Float64
        raise UnsafePathError.new(segment) unless raw.finite? && raw == raw.trunc && 0 <= raw <= Int32::MAX
        raw.to_i32.as(Seg)
      else
        raise UnsafePathError.new(segment)
      end
    end
  end

  def self.target_path_from_json(value : JSON::Any) : Path
    path = path_from_json(value)
    raise ArgumentError.new("path is empty") if path.empty?
    path
  end

  def self.count_from_json(value : JSON::Any, message : String) : Int32
    case raw = value.raw
    when Int64
      raise ArgumentError.new(message) if raw < 0
      Math.min(raw, Int32::MAX.to_i64).to_i32
    when Float64
      raise ArgumentError.new(message) unless raw.finite? && raw == raw.trunc && raw >= 0
      Math.min(raw, Int32::MAX.to_f64).to_i32
    else
      raise ArgumentError.new(message)
    end
  end

  def self.permutation_from_json(value : JSON::Any) : Array(Int32)
    entries = value.as_a? || raise ArgumentError.new("m permutation is not an array")
    entries.map { |entry| count_from_json(entry, "m permutation is not a bijection") }
  end

  private def self.wire_ref(ref : JSON::Any) : Nil
    case ref.raw
    when Int64, Float64
      count_from_json(ref, "bad path id")
    when Array
      path_from_json(ref)
    else
      raise ArgumentError.new("path is not an array")
    end
  end
end
