# src/llm-chord/ref.cr
module LLM::Chord
  enum RefOwner
    Object
    Call
    Host
    External
    Connection
    Client
  end

  alias StatusListener = Proc(RefStatus, Exception?, Nil)

  abstract class Ref
    @shape_listeners = Listeners(Proc(Shape, Nil)).new
    @status_listeners = Listeners(StatusListener).new

    abstract def contract : Contract
    abstract def address : String
    abstract def ready : Future(Nil)
    abstract def status : RefStatus
    abstract def error : Exception?
    abstract def variant : String?
    abstract def shape : Shape?
    abstract def state(name : String) : Readable
    abstract def release : Nil

    protected abstract def object : ObjectImpl?
    protected abstract def owner_host : Host
    protected abstract def dispatch(name : String, input : JSON::Any?, ctx : Ctx) : JSON::Any?

    def call(name : String, ctx : Ctx) : JSON::Any?
      call(name, nil, ctx)
    end

    def call(name : String, args = nil, ctx : Ctx? = nil) : JSON::Any?
      input = Chord.takes_no_args?(contract, name) ? nil : Chord.json_input(args)
      host = owner_host
      raise ChordError.new(ErrorCode::NotReady, "#{address}.#{name} called inside a factory") if host.in_factory > 0
      ctx.try &.check(host)
      if ctx && !ctx.holder?
        dispatch(name, input, ctx)
      else
        host.root(signal: ctx.try(&.signal)) { |root| dispatch(name, input, root) }
      end
    end

    def opaque(name : String, _type : T.class) : T? forall T
      case member = opaque_member(name)
      when Exposed     then member.resource.as(Resource(T)).open_value
      when OpaqueValue then member.as(OpaqueBox(T)).value
      end
    end

    def on_shape(&listener : Shape -> Nil) : Proc(Nil)
      @shape_listeners.remover(@shape_listeners.add(listener))
    end

    def on_status(&listener : RefStatus, Exception? -> Nil) : Proc(Nil)
      @status_listeners.remover(@status_listeners.add(listener))
    end

    def ended? : Bool
      status.released? || status.gone?
    end

    protected def opaque_member(name : String) : MemberValue?
      nil
    end

    protected def report(error : Exception) : Nil
      owner_host.report(error)
    end

    protected def status_changed : Nil
      return if @status_listeners.empty?
      listeners = @status_listeners.snapshot
      current = status
      failure = error
      Publish.enqueue { notify_status(listeners, current, failure) }
    end

    protected def notify_shape(current : Shape) : Nil
      listeners = @shape_listeners.snapshot
      Publish.enqueue { deliver_shape(listeners, current) }
    end

    protected def released_error : ChordError
      ChordError.new(ErrorCode::Released, "reference #{address} released")
    end

    private def notify_status(listeners, current : RefStatus, failure : Exception?) : Nil
      listeners.each do |(_, listener)|
        listener.call(current, failure)
      rescue thrown
        report(thrown)
      end
    end

    private def deliver_shape(listeners, current : Shape) : Nil
      listeners.each do |(_, listener)|
        listener.call(current)
      rescue thrown
        report(thrown)
      end
    end
  end

  class LocalRef < Ref
    getter contract : Contract
    getter address : String
    getter ready : Future(Nil)
    getter status : RefStatus
    getter error : Exception? = nil
    protected getter object : ObjectImpl
    protected getter owner : RefOwner
    @variants : Hash(String, Hash(String, MemberDescription))
    @gone_listeners = Listeners(Proc(Exception, Nil)).new
    @readables = {} of String => MemberReadable
    @bindings = {} of Service => Adapter?
    @views = {} of Implementation => Implementation

    def initialize(@object : ObjectImpl, @contract : Contract, @owner : RefOwner)
      @address = @object.address
      @variants = @contract.description.variants
      @status = @object.status.live? ? RefStatus::Live : RefStatus::Loading
      @ready = Future(Nil).new
      @object.ready.on_settle { settle_ready }
    end

    def state(name : String) : Readable
      @readables[name] ||= MemberReadable.new(self, name)
    end

    def variant : String?
      current_view.try(&.variant)
    end

    def shape : Shape?
      installed = @status.live? ? @object.current_installed : nil
      return unless installed
      view = safe_view(installed)
      return unless view
      Shape.new(view.variant, view.keys, installed.service.contract.fingerprint)
    end

    def release : Nil
      return if ended?
      @status = RefStatus::Released
      stop_readables
      status_changed
      @object.release(self)
    end

    protected def owner_host : Host
      @object.host
    end

    protected def dispatch(name : String, input : JSON::Any?, ctx : Ctx) : JSON::Any?
      @object.call(self, name, input, ctx)
    end

    protected def opaque_member(name : String) : MemberValue?
      view = current_view
      return if view.nil? || !in_variant?(view, name)
      view[name]?
    end

    protected def on_gone(&listener : Exception -> Nil) : Proc(Nil)
      @gone_listeners.remover(@gone_listeners.add(listener))
    end

    protected def live : Nil
      return unless @status.loading?
      @status = RefStatus::Live
      status_changed
      shape_changed
    end

    protected def gone(error : Exception) : Nil
      return if ended?
      @status = RefStatus::Gone
      @error = error
      stop_readables
      status_changed
      @gone_listeners.snapshot.each { |(_, listener)| listener.call(error) }
    end

    protected def shape_changed : Nil
      @readables.each_value(&.bind)
      current = shape
      notify_shape(current) if current
    end

    protected def terminal_error : Exception
      @status.gone? ? (@error || released_error) : released_error
    end

    protected def view_of(installed : Installed) : Implementation
      service = installed.service
      adapter = @bindings.fetch(service) { @bindings[service] = Chord.bind(service.contract, service.accepts, @contract) }
      return installed.implementation unless adapter
      @views[installed.implementation] ||= adapter.call(installed.implementation)
    end

    protected def forget_views(services : Array(Service), implementations : Array(Implementation)) : Nil
      @bindings.select! { |service, _| services.any?(&.same?(service)) }
      @views.select! { |implementation, _| implementations.any?(&.same?(implementation)) }
    end

    protected def current_view : Implementation?
      return unless @status.live?
      installed = @object.current_installed
      installed ? safe_view(installed) : nil
    end

    protected def describe(variant : String?, member : String) : MemberDescription?
      return @variants[variant]?.try(&.[member]?) if variant
      @variants.each_value { |members| members[member]?.try { |found| return found } }
      nil
    end

    protected def in_variant?(view : Implementation, name : String) : Bool
      !@contract.remote? || !describe(view.variant, name).nil?
    end

    private def settle_ready : Nil
      if failure = @object.ready.error
        @ready.reject(failure)
      elsif ended?
        @ready.reject(terminal_error)
      else
        @ready.resolve(nil)
      end
    end

    private def safe_view(installed : Installed) : Implementation?
      view_of(installed)
    rescue error
      report(error)
      nil
    end

    private def stop_readables : Nil
      @readables.each_value(&.stop)
    end
  end

  class MemberReadable < Readable
    @values = Listeners(Proc(JSON::Any, Nil)).new
    @events = Listeners(Proc(StateEvent, Nil)).new
    @unseen = ::Set(Int32).new
    @source : Readable? = nil
    @upstream : Proc(Nil)? = nil
    @seen : Tuple(JSON::Any)? = nil

    def initialize(@ref : LocalRef, @name : String); end

    def value : JSON::Any
      raise @ref.terminal_error if @ref.ended?
      raise Chord.not_ready("#{@ref.address}.#{@name}") unless @ref.status.live?
      view = @ref.current_view
      raise Chord.not_ready("#{@ref.address}.#{@name}") unless view
      source = current
      unless source
        raise ChordError.new(ErrorCode::NotInVariant,
          "#{@ref.address}: #{@name} is not a state member of variant #{view.variant || "(local)"}")
      end
      source.value
    end

    def hydrated? : Bool
      return false unless @ref.status.live?
      current.try(&.hydrated?) != false
    end

    def wait_hydrated : Nil
      return if hydrated?
      @ref.ready.wait
      current.try(&.wait_hydrated)
    end

    def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
      add_value(listener)
    end

    def events(&listener : StateEvent -> Nil) : Proc(Nil)
      add_event(listener)
    end

    protected def bind : Nil
      source = @values.size + @events.size > 0 ? current : nil
      previous = @source
      return if source.nil? ? previous.nil? : source.same?(previous)
      @upstream.try(&.call)
      @upstream = nil
      @source = source
      return unless source
      first = true
      @upstream = source.events do |event|
        forward(event, first)
        first = false
      end
    end

    protected def stop : Nil
      @values.clear
      @events.clear
      @unseen.clear
      bind
    end

    private def add_value(listener : Proc(JSON::Any, Nil)) : Proc(Nil)
      id = @values.add(listener)
      if source = readable
        current_value = source.value
        @seen = {current_value}
        safe { listener.call(current_value) }
      end
      bind
      remover(@values, id)
    end

    private def add_event(listener : Proc(StateEvent, Nil)) : Proc(Nil)
      id = @events.add(listener)
      if source = readable
        current_value = source.value
        @seen = {current_value}
        safe { listener.call(StateEvent.snap(current_value)) }
      else
        @unseen << id
      end
      bind
      -> { @unseen.delete(id); @events.delete(id); bind; nil }
    end

    private def remover(listeners : Listeners(Proc(JSON::Any, Nil)), id : Int32) : Proc(Nil)
      -> { listeners.delete(id); bind; nil }
    end

    private def forward(event : StateEvent, first : Bool) : Nil
      seen = @seen
      return if first && @unseen.empty? && seen && Json.identical?(event.value, seen[0])
      @seen = {event.value}
      translated = first ? StateEvent.reset(event.value) : event
      events = @events.snapshot
      values = @values.snapshot
      unseen = @unseen.dup
      @unseen.clear
      Publish.enqueue { deliver(events, values, unseen, translated, event.value) }
    end

    private def deliver(events, values, unseen : ::Set(Int32), translated : StateEvent, value : JSON::Any) : Nil
      events.each do |(id, listener)|
        next unless @events.includes?(id)
        delivered = unseen.includes?(id) ? StateEvent.snap(value) : translated
        safe { listener.call(delivered) }
      end
      values.each { |(id, listener)| safe { listener.call(value) } if @values.includes?(id) }
    end

    private def current : Readable?
      view = @ref.current_view
      return if view.nil? || !@ref.in_variant?(view, @name)
      view[@name]?.as?(Readable)
    end

    private def readable : Readable?
      source = current
      source if source && source.hydrated?
    end

    private def safe(&) : Nil
      yield
    rescue error
      @ref.report(error)
    end
  end
end
