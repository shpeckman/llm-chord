# src/llm-chord/delta/tracker.cr
require "weak_ref"

module LLM::Chord::Delta
  class OverlayError < Exception
  end

  enum Status
    Open
    Prepared
    Consumed
    Aborted
    Stale
  end

  class Overlay
    getter tracker : Tracker
    getter base : JSON::Any
    getter base_revision : Int64
    property status : Status
    property root : JSON::Any
    getter? released = false
    @root_draft : Draft? = nil
    @owned = ::Set(UInt64).new
    @copies = {} of UInt64 => JSON::Any
    @pins = [] of JSON::Any

    def initialize(@tracker : Tracker, @base : JSON::Any, @base_revision : Int64, @status : Status = Status::Open)
      @root = @base
    end

    def readable? : Bool
      !@released && (@status.open? || @status.prepared?)
    end

    def writable? : Bool
      !@released && @status.open?
    end

    def assert_readable : Nil
      raise OverlayError.new("Cannot use a settled overlay") unless readable?
    end

    def assert_writable : Nil
      raise OverlayError.new("Cannot use a settled overlay") unless writable?
    end

    def root_draft : Draft
      assert_readable
      @root_draft ||= Draft.new(self, @root, nil, nil, true)
    end

    def latest(value : JSON::Any) : JSON::Any
      return value unless Json.container?(value)
      @copies[identity(value)]? || value
    end

    def owned?(value : JSON::Any) : Bool
      Json.container?(value) && @owned.includes?(identity(value))
    end

    def copy(value : JSON::Any) : JSON::Any
      key = identity(value)
      if existing = @copies[key]?
        return existing
      end
      raw = value.raw
      duplicate = raw.is_a?(Array) ? JSON::Any.new(raw.dup) : JSON::Any.new(raw.as(Hash).dup)
      @copies[key] = duplicate
      @pins << value
      own(duplicate)
      duplicate
    end

    def place(value) : JSON::Any
      assert_writable
      placed = value.is_a?(Draft) ? value.value : Json.to_any(value)
      own(placed) if Json.container?(placed)
      placed
    end

    def abort : Nil
      @status = Status::Aborted if @status.open? || @status.prepared?
      release
    end

    def release : Nil
      @released = true
      @root = @base
      @root_draft = nil
      @owned.clear
      @copies.clear
      @pins.clear
    end

    private def own(value : JSON::Any) : Nil
      @owned.add(identity(value))
      @pins << value
    end

    private def identity(value : JSON::Any) : UInt64
      raw = value.raw
      raw.is_a?(Array) ? raw.object_id : raw.as(Hash).object_id
    end
  end

  class Prepared
    getter base : JSON::Any
    getter value : JSON::Any
    getter ops : Array(Op)
    getter overlay : Overlay

    def initialize(@overlay : Overlay, @value : JSON::Any, @ops : Array(Op))
      @base = @overlay.base
    end

    def base_revision : Int64
      @overlay.base_revision
    end

    def abort : Nil
      @overlay.abort
    end
  end

  class Change
    @settled = false
    @prepared = false

    def initialize(@overlay : Overlay); end

    def state : Draft
      raise OverlayError.new("Cannot use a settled overlay") if @settled
      @overlay.root_draft
    end

    def prepare : Prepared
      raise Exception.new("Change has already been settled") if @settled
      @overlay.assert_writable
      @overlay.status = Status::Prepared
      begin
        base = @overlay.base
        ops = Delta.diff_revisions(base, @overlay.root)
        value = ops.empty? ? base : Delta.apply_immutable(base, ops)
        prepared = Prepared.new(@overlay, value, ops)
        @prepared = true
        prepared
      rescue ex
        @overlay.status = Status::Aborted
        raise ex
      ensure
        @settled = true
        @overlay.release
      end
    end

    def abort : Nil
      if @settled
        @overlay.status = Status::Aborted if @prepared && @overlay.status.prepared?
        return
      end
      @settled = true
      @overlay.abort
    end
  end

  class Tracker
    getter value : JSON::Any
    getter revision : Int64 = 0_i64
    @overlays = [] of WeakRef(Overlay)
    @prune_budget = 256

    def initialize(@value : JSON::Any)
      Delta.assert_root(@value)
    end

    def begin_change : Change
      Change.new(register(Overlay.new(self, @value, @revision)))
    end

    def prepare_replace(value : JSON::Any) : Prepared
      Delta.assert_root(value)
      overlay = register(Overlay.new(self, @value, @revision, Status::Prepared))
      overlay.release
      if Json.equal?(@value, value)
        Prepared.new(overlay, @value, [] of Op)
      else
        Prepared.new(overlay, value, [Op::Replace.new(value)] of Op)
      end
    end

    def adopt(prepared : Prepared) : Nil
      overlay = prepared.overlay
      raise Exception.new("Prepared change belongs to a different tracker") unless overlay.tracker.same?(self)
      case overlay.status
      when .consumed? then raise Exception.new("Prepared change has already been used")
      when .aborted?  then raise Exception.new("Prepared change has been aborted")
      when .stale?    then raise Exception.new("Prepared change is stale")
      when .open?     then raise Exception.new("Prepared change is not ready")
      end
      if overlay.base_revision != @revision || !Json.identical?(@value, prepared.base)
        overlay.status = Status::Stale
        raise Exception.new("Prepared change is stale")
      end
      @value = prepared.value
      overlay.status = Status::Consumed
      @revision += 1
      invalidate(overlay)
    end

    private def register(overlay : Overlay) : Overlay
      @overlays << WeakRef.new(overlay)
      @prune_budget -= 1
      if @prune_budget == 0
        @overlays.reject! { |reference| reference.value.nil? }
        @prune_budget = Math.max(256, @overlays.size)
      end
      overlay
    end

    private def invalidate(winner : Overlay) : Nil
      @overlays.each do |reference|
        overlay = reference.value
        next if overlay.nil? || overlay.same?(winner)
        overlay.status = Status::Stale if overlay.status.open? || overlay.status.prepared?
        overlay.release
      end
      @overlays.clear
      @prune_budget = 256
    end
  end

  def self.assert_root(value : JSON::Any) : Nil
    raise ArgumentError.new("Tracked roots must be JSON objects or arrays") unless Json.container?(value)
  end

  def self.track(initial : JSON::Any) : Tracker
    Tracker.new(initial)
  end
end
