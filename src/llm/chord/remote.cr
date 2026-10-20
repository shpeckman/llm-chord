# src/llm/chord/remote.cr
module LLM::Chord
  enum BindingStatus
    Loading
    Live
    Ended
  end

  class MemberState
    property value : JSON::Any?
    property decoder : Delta::Decoder

    def initialize(@value : JSON::Any?)
      @decoder = Delta::Decoder.new
    end
  end

  class PendingShape
    getter shape : Shape
    getter missing : ::Set(String)
    getter values : Hash(String, MemberState)

    def initialize(@shape : Shape, @missing : ::Set(String), @values : Hash(String, MemberState)); end
  end

  class RemoteBinding
    getter host : Host
    getter key : String
    getter contract : Contract
    getter at : String
    getter input : JSON::Any
    getter principal : JSON::Any?
    getter status = BindingStatus::Loading
    getter error : Exception? = nil
    getter shape : Shape? = nil
    getter? hydrated = false
    getter hold : Tuple(Connection, Int64)? = nil
    getter? state_on = false
    getter? applied = false
    getter views = ::Set(RemoteRef).new
    getter members = {} of String => MemberState
    property linger_token = 0
    @variants : Hash(String, Hash(String, MemberDescription))
    @listeners = {} of String => ::Set(ViewReadable)
    @pending : PendingShape? = nil
    @live = Future(Nil).new
    @hydration = Future(Nil).new

    def initialize(@host : Host, @key : String, @contract : Contract, @at : String, @input : JSON::Any,
                   @principal : JSON::Any?)
      @variants = @contract.description.variants
    end

    def ended? : Bool
      @status.ended?
    end

    def state_views : Int32
      @views.count(&.wants_state?)
    end

    def wants_state? : Bool
      @views.empty? ? @state_on : state_views > 0
    end

    protected def add_view(view : RemoteRef) : Nil
      @views << view
      @linger_token += 1
      sync_state
      view.update
    end

    protected def remove_view(view : RemoteRef) : Nil
      return unless @views.delete(view)
      @listeners.each_value { |set| set.reject!(&.view.same?(view)) }
      if @views.empty?
        @host.binding_idle(self)
        return
      end
      sync_state
    end

    protected def listen(name : String, readable : ViewReadable) : Nil
      (@listeners[name] ||= ::Set(ViewReadable).new) << readable
    end

    protected def unlisten(name : String, readable : ViewReadable) : Nil
      @listeners[name]?.try &.delete(readable)
    end

    def in_variant?(name : String) : Bool
      variant = @shape.try(&.variant)
      !variant.nil? && @variants[variant]?.try(&.[name]?).try(&.state?) == true
    end

    def read(name : String) : JSON::Any
      raise terminal_error if ended?
      raise ChordError.new(ErrorCode::NotReady, "#{@key}.#{name} is not hydrated yet") unless @hydrated
      unless in_variant?(name)
        raise ChordError.new(ErrorCode::NotInVariant, "#{@key}: #{name} is not a state member of variant #{@shape.try(&.variant)}")
      end
      @members[name]?.try(&.value) || JSON::Any.new(nil)
    end

    def when_hydrated : Future(Nil)
      return Future(Nil).resolved(nil) if @hydrated
      if ended?
        failed = Future(Nil).new
        failed.reject(terminal_error)
        return failed
      end
      @hydration
    end

    def readable?(name : String) : Bool
      !ended? && @hydrated && in_variant?(name)
    end

    def terminal_error : Exception
      @error || ChordError.new(ErrorCode::Released, "reference #{@key} released")
    end

    protected def bound(connection : Connection, id : Int64) : Nil
      @hold = {connection, id}
      @state_on = wants_state?
    end

    protected def shaped(shape : Shape, listed : Array(String)) : Nil
      return if ended?
      previous = @pending
      missing = listed.to_set
      previous.try &.missing.each { |name| missing << name }
      wanted = state_members(shape).to_set
      missing = missing.select { |name| wanted.includes?(name) && @state_on }.to_set
      @pending = PendingShape.new(shape, missing, previous.try(&.values) || {} of String => MemberState)
      apply if missing.empty?
    end

    protected def state(name : String, frame : Frame, value : JSON::Any?) : Nil
      return if ended?
      kind = frame.string("as")
      if kind == "error"
        error = Wire.from_error(frame["error"])
        if !@hydrated && @state_on
          gone(error)
          close
        else
          @host.report(error)
        end
        return
      end
      pending = @pending
      if kind == "ops"
        target = pending.try(&.values[name]?) || @members[name]?
        return unless target
        ops = target.decoder.decode(frame["ops"]?.try(&.as_a) || [] of JSON::Any)
        updated = Delta.apply_immutable(target.value || JSON::Any.new(nil), ops)
        target.value = updated
        deliver(name, StateEvent.ops(ops, updated)) if target.same?(@members[name]?)
        return
      end
      fresh = MemberState.new(value)
      if pending && (pending.missing.includes?(name) || pending.values.has_key?(name))
        pending.values[name] = fresh
        pending.missing.delete(name)
        apply if pending.missing.empty?
        return
      end
      return unless in_variant?(name)
      @members[name] = fresh
      deliver(name, StateEvent.reset(value || JSON::Any.new(nil)))
    end

    protected def gone(error : Exception) : Nil
      return if ended?
      @status = BindingStatus::Ended
      @error = error
      @hold = nil
      @pending = nil
      @live.reject(error)
      @hydration.reject(error)
      @views.to_a.each(&.finish(error))
      @listeners.clear
      @host.forget_binding(self)
    end

    protected def detached : Nil
      return if ended?
      @hold = nil
      @pending = nil
      if @status.live?
        @status = BindingStatus::Loading
        @live = Future(Nil).new
      end
      @views.to_a.each(&.update)
    end

    protected def close : Nil
      @linger_token += 1
      if hold = @hold
        hold[0].release(hold[1])
      end
      @hold = nil
      unless ended?
        @status = BindingStatus::Ended
        error = ChordError.new(ErrorCode::Released, "reference #{@key} released")
        @live.reject(error)
        @hydration.reject(error)
        @views.to_a.each(&.finish(error))
      end
      @pending = nil
      @listeners.clear
      @host.forget_binding(self)
    end

    protected def call(name : String, args : JSON::Any?, ctx : Ctx) : JSON::Any?
      loop do
        raise terminal_error if ended?
        Chord.race(@live, ctx.signal) if !@status.live? || @hold.nil?
        hold = @hold
        next if hold.nil? || !@status.live?
        variant = @shape.try(&.variant)
        description = variant ? @variants[variant]?.try(&.[name]?) : nil
        unless description.try(&.method?)
          raise ChordError.new(ErrorCode::NotInVariant, "#{@key}: #{name} is not a method of variant #{variant}")
        end
        expected = description.try(&.args)
        sent = expected ? TypeBox::Value.clean(expected, TypeBox::Value.clone(args)) : nil
        return hold[0].call(hold[1], name, sent, ctx.root_id, ctx.code_version, ctx.signal)
      end
    end

    private def sync_state : Nil
      return if ended? || @views.empty?
      wanted = state_views > 0
      return if wanted == @state_on
      @state_on = wanted
      unless wanted
        @hydrated = false
        @hydration = Future(Nil).new if @hydration.settled?
        @members.clear
        @pending.try &.missing.clear
      end
      if hold = @hold
        hold[0].want_state(hold[1], wanted)
      end
      @views.to_a.each(&.update)
    end

    private def state_members(shape : Shape) : Array(String)
      variant = shape.variant
      members = variant ? @variants[variant]? : nil
      return [] of String unless members
      shape.members.select { |name| members[name]?.try(&.state?) }
    end

    private def apply : Nil
      pending = @pending
      return unless pending
      @pending = nil
      @shape = pending.shape
      wanted = state_members(pending.shape).to_set
      @members.reject! { |name, _| !wanted.includes?(name) }
      pending.values.each { |name, state| @members[name] = state if wanted.includes?(name) }
      @hydrated = @state_on && wanted.all? { |name| @members.has_key?(name) }
      @hydration.resolve(nil) if @hydrated
      @status = BindingStatus::Live
      @applied = true
      @live.resolve(nil)
      @views.to_a.each(&.update)
      pending.values.each do |name, state|
        deliver(name, StateEvent.reset(state.value || JSON::Any.new(nil))) if wanted.includes?(name)
      end
      @views.to_a.each(&.shape_changed)
    end

    private def deliver(name : String, event : StateEvent) : Nil
      @listeners[name]?.try &.to_a.each(&.deliver(event))
    end
  end

  class ViewReadable < Readable
    getter view : RemoteRef
    @values = Listeners(Proc(JSON::Any, Nil)).new
    @events = Listeners(Proc(StateEvent, Nil)).new
    @unseen = ::Set(Int32).new

    def initialize(@view : RemoteRef, @name : String); end

    def value : JSON::Any
      raise @view.terminal_error if @view.ended?
      @view.binding.read(@name)
    end

    def hydrated? : Bool
      @view.binding.hydrated?
    end

    def wait_hydrated : Nil
      @view.binding.when_hydrated.wait
    end

    def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
      add_value(listener)
    end

    def events(&listener : StateEvent -> Nil) : Proc(Nil)
      add_event(listener)
    end

    protected def deliver(event : StateEvent) : Nil
      @events.snapshot.each do |(id, listener)|
        next unless @events.includes?(id)
        if !@unseen.delete(id)
          safe { listener.call(event) }
        elsif !event.kind.ops?
          safe { listener.call(StateEvent.snap(event.value)) }
        end
      end
      @values.snapshot.each { |(id, listener)| safe { listener.call(event.value) } if @values.includes?(id) }
    end

    protected def stop : Nil
      @values.clear
      @events.clear
      @unseen.clear
      @view.binding.unlisten(@name, self)
    end

    private def add_value(listener : Proc(JSON::Any, Nil)) : Proc(Nil)
      id = @values.add(listener)
      attach
      safe { listener.call(current) } if readable?
      remover(@values, id)
    end

    private def add_event(listener : Proc(StateEvent, Nil)) : Proc(Nil)
      id = @events.add(listener)
      attach
      if readable?
        safe { listener.call(StateEvent.snap(current)) }
      else
        @unseen << id
      end
      -> { @unseen.delete(id); @events.delete(id); detach_if_idle; nil }
    end

    private def remover(listeners : Listeners(Proc(JSON::Any, Nil)), id : Int32) : Proc(Nil)
      -> { listeners.delete(id); detach_if_idle; nil }
    end

    private def current : JSON::Any
      @view.binding.members[@name]?.try(&.value) || JSON::Any.new(nil)
    end

    private def readable? : Bool
      !@view.ended? && @view.binding.readable?(@name)
    end

    private def attach : Nil
      @view.binding.listen(@name, self) unless @view.ended?
    end

    private def detach_if_idle : Nil
      @view.binding.unlisten(@name, self) if @values.size + @events.size == 0
    end

    private def safe(&) : Nil
      yield
    rescue error
      @view.binding.host.report(error)
    end
  end

  class RemoteRef < Ref
    getter binding : RemoteBinding
    getter ready : Future(Nil) = Future(Nil).new
    getter status : RefStatus = RefStatus::Loading
    getter error : Exception? = nil
    getter? wants_state : Bool
    protected getter owner : RefOwner
    @readables = {} of String => ViewReadable

    def initialize(@binding : RemoteBinding, @owner : RefOwner, @wants_state : Bool); end

    def contract : Contract
      @binding.contract
    end

    def address : String
      @binding.key
    end

    def variant : String?
      @binding.shape.try(&.variant)
    end

    def shape : Shape?
      @binding.shape
    end

    def state(name : String) : Readable
      @readables[name] ||= ViewReadable.new(self, name)
    end

    def release : Nil
      return if ended?
      @status = RefStatus::Released
      status_changed
      @ready.reject(released_error)
      @readables.each_value(&.stop)
      @binding.remove_view(self)
    end

    def terminal_error : Exception
      @status.gone? ? (@error || released_error) : released_error
    end

    protected def object : ObjectImpl?
      nil
    end

    protected def owner_host : Host
      @binding.host
    end

    protected def dispatch(name : String, input : JSON::Any?, ctx : Ctx) : JSON::Any?
      raise terminal_error if ended?
      @binding.call(name, input, ctx)
    end

    protected def update : Nil
      return if ended?
      live = @binding.status.live? && !@binding.hold.nil? && (!@wants_state || @binding.hydrated?)
      following = live ? RefStatus::Live : RefStatus::Loading
      return if following == @status
      @status = following
      status_changed
      @ready.resolve(nil) if live
    end

    protected def finish(error : Exception) : Nil
      return if ended?
      released = error.is_a?(ChordError) && error.code.released?
      @status = released ? RefStatus::Released : RefStatus::Gone
      @error = error unless released
      status_changed
      @ready.reject(error)
      @readables.each_value(&.stop)
    end

    protected def shape_changed : Nil
      current = @binding.shape
      return if current.nil? || ended?
      notify_shape(current)
    end
  end
end
