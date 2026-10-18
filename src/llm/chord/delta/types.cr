# src/llm/chord/delta/types.cr
module LLM::Chord::Delta
  alias Seg = String | Int32
  alias Path = Array(Seg)

  abstract struct Op
    abstract def verb : Char

    struct Replace < Op
      getter value : JSON::Any

      def initialize(@value : JSON::Any); end

      def verb : Char
        'r'
      end
    end

    struct Set < Op
      getter path : Path
      getter value : JSON::Any

      def initialize(@path : Path, @value : JSON::Any); end

      def verb : Char
        's'
      end
    end

    struct Delete < Op
      getter path : Path

      def initialize(@path : Path); end

      def verb : Char
        'd'
      end
    end

    struct Append < Op
      getter path : Path
      getter text : String

      def initialize(@path : Path, @text : String); end

      def verb : Char
        'a'
      end
    end

    struct Truncate < Op
      getter path : Path
      getter count : Int32

      def initialize(@path : Path, @count : Int32); end

      def verb : Char
        't'
      end
    end

    struct Splice < Op
      getter path : Path
      getter index : Int32
      getter remove : Int32
      getter items : Array(JSON::Any)

      def initialize(@path : Path, @index : Int32, @remove : Int32, @items : Array(JSON::Any)); end

      def verb : Char
        'p'
      end
    end

    struct Move < Op
      getter path : Path
      getter permutation : Array(Int32)

      def initialize(@path : Path, @permutation : Array(Int32)); end

      def verb : Char
        'm'
      end
    end
  end

  RESERVED_SEGMENTS = ["__proto__", "constructor", "prototype"]

  class UnsafePathError < Exception
    getter segment : Seg

    def initialize(@segment : Seg)
      super("unsafe path segment: #{segment.inspect}")
    end
  end

  class PathError < Exception
    getter path : Path | Int64

    def initialize(@path : Path | Int64)
      super("unresolvable path: #{path.inspect}")
    end
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
end
