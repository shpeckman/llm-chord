# src/llm/chord/cell.cr
module LLM::Chord
  alias WriteGuard = Proc(Ctx, Nil)
  alias Reporter = Proc(Exception, Nil)

  record SourceOptions, dev : Bool, report : Reporter

  class Fanout
    @values = Listeners(Proc(JSON::Any, Nil)).new
    @events = Listeners(Proc(StateEvent, Nil)).new

    def initialize(@report : Reporter); end

    def subscribe(listener : Proc(JSON::Any, Nil), current : JSON::Any) : Proc(Nil)
      id = @values.add(listener)
      call(listener, current)
      @values.remover(id)
    end

    def events(listener : Proc(StateEvent, Nil), current : JSON::Any) : Proc(Nil)
      id = @events.add(listener)
      call(listener, StateEvent.snap(current))
      @events.remover(id)
    end

    def emit(event : StateEvent) : Nil
      events = @events.snapshot
      values = @values.snapshot
      Publish.enqueue { deliver(events, values, event) }
    end

    private def deliver(events, values, event : StateEvent) : Nil
      events.each { |(id, listener)| call(listener, event) if @events.includes?(id) }
      values.each { |(id, listener)| call(listener, event.value) if @values.includes?(id) }
    end

    private def call(listener : Proc(V, Nil), value : V) : Nil forall V
      listener.call(value)
    rescue error
      @report.call(error)
    end
  end

  abstract class Source < Readable
    @@sequence = 0_i64

    getter key : String
    getter seq : Int64
    getter dependents = ::Set(Derived).new
    property schemas = [] of Schema::Source
    @options : SourceOptions
    @fanout : Fanout

    def initialize(@key : String, @options : SourceOptions)
      @@sequence += 1
      @seq = @@sequence
      @fanout = Fanout.new(@options.report)
    end

    def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
      @fanout.subscribe(listener, value)
    end

    def events(&listener : StateEvent -> Nil) : Proc(Nil)
      @fanout.events(listener, value)
    end

    def validate(value : JSON::Any) : Nil
      return unless @options.dev
      own_schemas.each { |schema| Schema.assert_valid("state", "state #{@key}", schema, value) }
      @schemas.each { |schema| Schema.assert_valid("state", "state #{@key}", schema, value) }
    end

    protected def own_schemas : Array(Schema::Source)
      [] of Schema::Source
    end

    def self.compute_dependents(changed : Source, value : JSON::Any, checked : Bool = true) : Hash(Derived, JSON::Any)
      pending = ::Set(Derived).new
      collect(changed, pending)
      values = {changed.as(Readable) => value}
      result = {} of Derived => JSON::Any
      pending.to_a.sort_by!(&.seq).each do |derived|
        computed = derived.compute { |source| values.fetch(source) { source.value } }
        derived.validate(computed) if checked
        values[derived] = computed
        result[derived] = computed
      end
      result
    end

    private def self.collect(source : Source, pending : ::Set(Derived)) : Nil
      source.dependents.each do |derived|
        next if pending.includes?(derived)
        pending << derived
        collect(derived, pending)
      end
    end
  end

  class Cell < Source
    getter schema : TypeBox::Schema
    @tracker : Delta::Tracker
    @guard : WriteGuard
    @initialized : Bool

    def initialize(key : String, @schema : TypeBox::Schema, initial : JSON::Any?, @guard : WriteGuard, options : SourceOptions)
      Schema.assert_valid("state", "initial value of state #{key}", @schema, initial) if initial
      @tracker = Delta.track(Cell.box(initial || JSON::Any.new(nil)))
      @initialized = !initial.nil?
      super(key, options)
    end

    def value : JSON::Any
      raise uninitialized_error unless @initialized
      @tracker.value["v"]
    end

    def change(ctx : Ctx, & : Delta::Draft -> _) : Nil
      writable(ctx)
      change = @tracker.begin_change
      prepared = begin
        yield change.state["v"]
        change.prepare
      rescue error
        change.abort
        raise error
      end
      publish(prepared, StateEvent::Kind::Ops)
    end

    def update(ctx : Ctx, & : JSON::Any -> _) : Nil
      writable(ctx)
      result = Chord.json_value(yield value)
      Schema.assert_valid("state", "state #{key}", @schema, result)
      change = @tracker.begin_change
      prepared = begin
        change.state["v"] = result
        change.prepare
      rescue error
        change.abort
        raise error
      end
      publish(prepared, StateEvent::Kind::Ops)
    end

    def replace(ctx : Ctx, value, diff : Bool? = nil) : Nil
      writable(ctx)
      after = Chord.json_value(value)
      before = self.value
      ops = (diff.nil? ? Cell.shares_structure?(before, after) : diff) ? Delta.diff_revisions(before, after) : nil
      publish(@tracker.prepare_replace(Cell.box(after)), StateEvent::Kind::Ops, true, ops)
    end

    protected def fill(value : JSON::Any) : Nil
      raise Exception.new("state #{key} is already initialized") if @initialized
      Schema.assert_valid("state", "initial value of state #{key}", @schema, value)
      @tracker = Delta.track(Cell.box(value))
      @initialized = true
    end

    protected def own_schemas : Array(Schema::Source)
      [@schema] of Schema::Source
    end

    private def writable(ctx : Ctx) : Nil
      @guard.call(ctx)
      raise uninitialized_error unless @initialized
    end

    private def uninitialized_error : ChordError
      Chord.not_ready("state #{key} (its init has not run)")
    end

    private def publish(prepared : Delta::Prepared, kind : StateEvent::Kind, checked : Bool = true, ops : Array(Delta::Op)? = nil) : Nil
      if prepared.ops.empty? && kind.ops?
        @tracker.adopt(prepared)
        return
      end
      value = prepared.value["v"]
      candidates = begin
        validate(value) if checked
        Source.compute_dependents(self, value, checked)
      rescue error
        prepared.abort
        raise error
      end
      Publish.hold do
        @tracker.adopt(prepared)
        published = ops && !ops.empty? ? ops : Cell.unbox(prepared.ops, value)
        @fanout.emit(kind.reset? ? StateEvent.reset(value) : StateEvent.ops(published, value))
        candidates.each { |derived, computed| derived.install(computed) }
      end
    end

    protected def self.box(value : JSON::Any) : JSON::Any
      JSON::Any.new({"v" => value})
    end

    protected def self.unbox(ops : Array(Delta::Op), value : JSON::Any) : Array(Delta::Op)
      replaced = [Delta::Op::Replace.new(value)] of Delta::Op
      result = [] of Delta::Op
      ops.each do |op|
        return replaced unless op.is_a?(Delta::Op::Targeted) && !op.path.empty?
        path = op.path[1..]
        return replaced if path.empty? && !op.is_a?(Delta::Op::Splice) && !op.is_a?(Delta::Op::Move)
        result << Delta::Op.from_tuple(JSON::Any.new([JSON::Any.new(op.verb.to_s), Delta.path_to_json(path)] + op.arguments))
      end
      result
    end

    protected def self.shares_structure?(before : JSON::Any, after : JSON::Any) : Bool
      a = before.raw
      b = after.raw
      if a.is_a?(Hash) && b.is_a?(Hash)
        return false if a.same?(b)
        b.any? { |key, child| Json.container?(child) && (old = a[key]?) && Json.identical?(old, child) }
      elsif a.is_a?(Array) && b.is_a?(Array)
        return false if a.same?(b)
        b.each_with_index.any? { |child, index| Json.container?(child) && index < a.size && Json.identical?(a[index], child) }
      else
        false
      end
    end
  end

  class Derived < Source
    getter sources : Array(Readable)
    @fn : Proc(Array(JSON::Any), JSON::Any)
    @value : JSON::Any? = nil
    @external = [] of Proc(Nil)

    def initialize(key : String, @sources : Array(Readable), @fn : Proc(Array(JSON::Any), JSON::Any), options : SourceOptions)
      super(key, options)
    end

    def value : JSON::Any
      @value || JSON::Any.new(nil)
    end

    def hydrated? : Bool
      @sources.all?(&.hydrated?)
    end

    def wait_hydrated : Nil
      @sources.each(&.wait_hydrated)
    end

    def compute(& : Readable -> JSON::Any) : JSON::Any
      @fn.call(@sources.map { |source| yield source })
    end

    protected def attach : Nil
      @value = compute(&.value)
      @sources.each do |source|
        if source.is_a?(Source)
          source.dependents << self
        else
          @external << source.subscribe { refresh }
        end
      end
    end

    protected def detach : Nil
      @sources.each { |source| source.dependents.delete(self) if source.is_a?(Source) }
      @external.each(&.call)
      @external.clear
    end

    protected def refresh : Nil
      computed = compute(&.value)
      dependents = Source.compute_dependents(self, computed)
      Publish.hold do
        install(computed)
        dependents.each { |derived, value| derived.install(value) }
      end
    rescue error
      @options.report.call(error)
    end

    protected def install(computed : JSON::Any) : Nil
      before = @value
      @value = computed
      ops = before.nil? ? [Delta::Op::Replace.new(computed)] of Delta::Op : Delta.diff_revisions(before, computed)
      @fanout.emit(StateEvent.ops(ops, computed)) unless ops.empty?
    end
  end
end
