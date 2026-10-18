# src/llm/chord/delta/tracker.cr
module LLM::Chord::Delta
  class Prepared
    getter base : JSON::Any
    getter value : JSON::Any
    getter ops : Array(Op)
    getter base_revision : Int32

    def initialize(@tracker_id : UInt64, @base : JSON::Any, @value : JSON::Any, @ops : Array(Op), @base_revision : Int32)
      @aborted = false
    end

    def abort : Nil
      @aborted = true
    end

    def aborted? : Bool
      @aborted
    end

    def tracker_id : UInt64
      @tracker_id
    end
  end

  class Change
    def initialize(@tracker_id : UInt64, @base : JSON::Any, @base_revision : Int32)
      @state = Json.deep_copy(@base)
      @settled = false
    end

    def state : JSON::Any
      raise Exception.new("Cannot use a settled change") if @settled
      @state
    end

    def prepare : Prepared
      raise Exception.new("Change has already been settled") if @settled
      @settled = true
      ops = LLM::Chord::Delta.diff_revisions(@base, @state)
      value = ops.empty? ? @base : @state
      Prepared.new(@tracker_id, @base, value, ops, @base_revision)
    end

    def abort : Nil
      @settled = true
    end
  end

  class Tracker
    @@next_id = 0_u64
    @id : UInt64

    getter value : JSON::Any
    getter revision : Int32

    def initialize(@value : JSON::Any)
      @revision = 0
      @id = @@next_id
      @@next_id += 1
    end

    def begin_change : Change
      Change.new(@id, @value, @revision)
    end

    def prepare_replace(value : JSON::Any) : Prepared
      ops = Diff.revisions(@value, value)
      result = ops.empty? ? @value : value
      Prepared.new(@id, @value, result, ops, @revision)
    end

    def adopt(prepared : Prepared) : Nil
      raise Exception.new("Prepared change belongs to a different tracker") unless prepared.tracker_id == @id
      raise Exception.new("Prepared change has been aborted") if prepared.aborted?
      raise Exception.new("Prepared change is stale") unless prepared.base_revision == @revision
      @value = prepared.value
      @revision += 1
    end
  end

  def self.track(initial : JSON::Any) : Tracker
    Tracker.new(initial)
  end
end
