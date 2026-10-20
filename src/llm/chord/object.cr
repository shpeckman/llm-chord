# src/llm/chord/object.cr
module LLM::Chord
  enum Lifetime
    Referenced
    Host
  end

  alias Adapter = Proc(Implementation, Implementation)
  alias Accepts = Hash(Int32, Adapter)
  alias Factory = Proc(JSON::Any, JSON::Any, ObjectScope, Implementation)
  alias TaskFn = Proc(Ctx, Nil)
  alias InitFn = Proc(Ctx, JSON::Any)
  alias ListenerFn = Proc(JSON::Any, Ctx, Nil)

  class Service
    getter contract : Contract
    getter factory : Factory
    getter lifetime : Lifetime
    getter linger : Time::Span?
    getter accepts : Accepts?
    getter facet : String

    def initialize(@contract : Contract, @factory : Factory, @lifetime : Lifetime, @linger : Time::Span?,
                   @accepts : Accepts?, @facet : String)
      check_lifetime
    end

    def host_lifetime? : Bool
      @lifetime.host?
    end

    private def check_lifetime : Nil
      return unless host_lifetime?
      name = @contract.name
      raise ArgumentError.new(%(#{name}: lifetime "host" needs a local type (remote types are referenced))) if @contract.remote?
      raise ArgumentError.new(%(#{name}: an object of lifetime "host" does not linger (it lives as long as the host))) if @linger
      begin
        Schema.normalize(@contract.input, nil, "#{name} input")
      rescue ChordError
        raise ArgumentError.new(%(#{name}: lifetime "host" needs an input that accepts {} (the object's one address)))
      end
    end
  end

  record ListenerDecl, origin : AnyResource | Subscribable, source : Proc(Subscribable), select : (Proc(AnyResource, Subscribable))?, fn : ListenerFn

  class Decls
    getter cells = {} of String => Cell
    getter cell_schemas = {} of String => TypeBox::Schema
    getter cell_versions = {} of String => Int32
    getter cell_migrations = {} of String => Proc(JSON::Any, Int32, JSON::Any)
    getter refs = {} of String => Ref
    getter resources = {} of String => AnyResource
    getter adopted = {} of AnyResource => Proc(Nil)
    getter listeners = {} of String => ListenerDecl
    getter tasks = {} of String => TaskFn
    getter derives = {} of String => Derived
    getter registrations = {} of String => Registration
  end

  class Run
    getter decls = Decls.new
    getter created_refs = [] of Ref
    getter created_resources = [] of AnyResource
    getter created_derives = [] of Derived
    getter inits = [] of Tuple(Cell, InitFn)
    property implementation : Implementation? = nil
  end

  record Installed, code_version : Int32, service : Service, implementation : Implementation, decls : Decls

  record Gate, grandfathered : ::Set(String), queue : Array(Tuple(String, JSON::Any)), drained : Proc(Nil)

  record StagedListeners, activate : Proc(Nil), discard : Proc(Nil)

  private record Subscription, origin : AnyResource | Subscribable, select : (Proc(AnyResource, Subscribable))?,
    unsubscribe : Proc(Nil), buffer : Array(JSON::Any)?

  enum ObjectStatus
    Activating
    Live
    Failed
    Disposing
    Disposed

    def label : String
      to_s.downcase
    end
  end

  class ObjectImpl
    getter host : Host
    getter address : String
    getter type_name : String
    getter input : JSON::Any
    getter principal : JSON::Any
    getter? host_lifetime : Bool
    getter status = ObjectStatus::Activating
    getter ready = Future(Nil).new
    getter decls = Decls.new
    getter call_abort = AbortController.new
    getter implementations = {} of Int32 => Installed
    @service : Service? = nil
    @pending = ::Set(Decls).new
    @refs = ::Set(LocalRef).new
    @open_order = [] of AnyResource
    @activation_abort = AbortController.new
    @subscriptions = {} of String => Proc(Nil)
    @invocations = ::Set(Future(Nil)).new
    @tasks = {} of String => Tuple(AbortController, Future(Nil))
    @stopped = ::Set(Future(Nil)).new
    @linger_token = 0
    @lingering = false
    @disposal : Future(Nil)? = nil
    @guard : WriteGuard? = nil

    def initialize(@host : Host, @address : String, @type_name : String, @input : JSON::Any, @principal : JSON::Any,
                   @host_lifetime : Bool)
    end

    protected def guard : WriteGuard
      @guard ||= ->(ctx : Ctx) { check_write(ctx) }
    end

    protected def start(after : Future(Nil)?) : Nil
      spawn { run_activation(after) }
    end

    protected def all_decls : ::Set(Decls)
      result = ::Set{@decls}
      result.concat(@pending)
      @implementations.each_value { |installed| result << installed.decls }
      result
    end

    protected def current_installed : Installed?
      @implementations[@host.code_version]? || @implementations.values.last?
    end

    protected def call(ref : LocalRef, name : String, args : JSON::Any?, ctx : Ctx) : JSON::Any?
      ctx.check(@host)
      raise ref.terminal_error if ref.status.released? || ref.status.gone?
      Chord.race(ref.ready, ctx.signal) if ref.status.loading?
      unless ref.status.live? && @status.live?
        raise ref.status.live? ? ChordError.new(ErrorCode::Gone, "#{@address} is #{@status.label}") : ref.terminal_error
      end
      admit(ctx)
      installed = @implementations[ctx.code_version]?
      unless installed
        raise ChordError.new(ErrorCode::Superseded, "#{@address} has no implementation for code version #{ctx.code_version}")
      end
      view = ref.view_of(installed)
      variant = view.variant
      remote = ref.contract.remote?
      wanted = ref.describe(remote ? variant : LOCAL_VARIANT, name)
      fn = view[name]?
      unless fn.is_a?(MethodFn) && (!remote || wanted.try(&.method?))
        raise ChordError.new(ErrorCode::NotInVariant, "#{@address}: #{name} is not a method of variant #{variant || "(local)"}")
      end
      schema = view.same?(installed.implementation) ? installed.service.contract.description.variants[variant || LOCAL_VARIANT]?.try(&.[name]?) : wanted
      method = schema.try { |found| found.method? ? found : nil }
      validated = remote ? method : nil
      takes_args = method.nil? || !method.args.nil?
      input = takes_args ? method_input(remote ? wanted : nil, validated, name, args) : nil
      child = ctx.child(self)
      result = begin
        invoke { fn.call(input, child) }
      ensure
        child.close
      end
      return nil unless method.nil? || method.result
      if expected = validated.try(&.result)
        Schema.assert_valid("result", "#{@address}.#{name} result", expected, result)
      end
      result
    end

    protected def add_ref(ref : LocalRef) : Nil
      @refs << ref
      @linger_token += 1
      @lingering = false
    end

    protected def release(ref : LocalRef) : Nil
      maybe_idle if @refs.delete(ref)
    end

    protected def dispose(forced : Bool, reason : Exception? = nil) : Future(Nil)
      if disposal = @disposal
        return disposal
      end
      disposal = Future(Nil).new
      @disposal = disposal
      was_activating = @status.activating?
      @status = ObjectStatus::Disposing
      @host.forget(self)
      @lingering = false
      @linger_token += 1
      error = reason || ChordError.new(ErrorCode::Gone, "#{@address} was disposed")
      if forced
        @refs.to_a.each(&.gone(error))
        @call_abort.abort(error)
      end
      @activation_abort.abort(error)
      spawn { finish_dispose(was_activating, error, disposal) }
      disposal
    end

    private def run_activation(after : Future(Nil)?) : Nil
      begin
        activate(after)
      rescue cause
        @status = ObjectStatus::Failed if @status.activating?
        @host.forget(self)
        error = Chord.as_chord_error(cause, "activating #{@address}")
        @refs.to_a.each(&.gone(error))
        @ready.reject(error)
        return
      end
      @refs.to_a.each(&.live)
      maybe_idle
      @ready.resolve(nil)
    end

    private def activate(after : Future(Nil)?) : Nil
      after.try(&.await_settled)
      signal = @activation_abort.signal
      raise abandoned if signal.aborted?
      service = @host.service(@type_name)
      raise ChordError.new(ErrorCode::Unavailable, "#{@type_name} is not served", reason: "unknown_type") unless service
      @service = service
      run = run_factory(service)
      begin
        open(run.created_resources, run.created_refs)
        raise abandoned if signal.aborted?
        wait_hydrated(run)
        raise abandoned if signal.aborted?
        init_cells(run, signal)
        raise abandoned if signal.aborted?
        @host.check_registrations(self, run.decls)
        @decls = run.decls
        code_version = @host.code_version
        @implementations[code_version] = Installed.new(code_version, service, run.implementation.not_nil!, run.decls)
        run.created_derives.each(&.attach)
        refresh_schemas
        @host.registries_changed(self) unless run.decls.registrations.empty?
        start_runtime
        raise abandoned if signal.aborted?
        @status = ObjectStatus::Live
      rescue error
        @call_abort.abort(error)
        stop_listeners
        stop_tasks
        registered = !@decls.registrations.empty?
        @implementations.clear
        @decls = Decls.new
        @host.registries_changed if registered
        (@invocations.to_a + @stopped.to_a).each(&.await_settled)
        cleanup(run)
        raise error
      ensure
        @pending.delete(run.decls)
      end
    end

    private def abandoned : ChordError
      ChordError.new(ErrorCode::Aborted, "#{@address} abandoned")
    end

    private def run_factory(service : Service) : Run
      scope = ObjectScope.new(self)
      run = scope.run
      @pending << run.decls
      @host.in_factory += 1
      implementation = begin
        service.factory.call(@input, @principal, scope)
      rescue error
        @host.in_factory -= 1
        discard(run)
        raise error
      end
      @host.in_factory -= 1
      run.implementation = implementation
      begin
        Chord.validate_implementation(service, implementation)
      rescue error
        discard(run)
        raise error
      end
      run
    end

    private def discard(run : Run) : Nil
      @pending.delete(run.decls)
      spawn { cleanup(run) }
    end

    private def cleanup(run : Run) : Nil
      unwind(run)
    rescue error
      @host.report(error)
    end

    private def open(resources : Array(AnyResource), refs : Array(Ref)) : Nil
      signal = @activation_abort.signal
      opening = {} of AnyResource => Future(Nil)
      futures = resources.map { |resource| open_one(resource, resources, opening, signal) }
      references = Future(Nil).run { refs.each(&.ready.wait) }
      ready = Future(Nil).run do
        within_ready_timeout(references) { refs.select(&.status.loading?).map(&.address) }
      end
      Chord.await_all(futures + [ready])
    end

    private def open_one(resource : AnyResource, resources : Array(AnyResource), opening : Hash(AnyResource, Future(Nil)),
                         signal : AbortSignal) : Future(Nil)
      if existing = opening[resource]?
        return existing
      end
      future = Future(Nil).new
      opening[resource] = future
      spawn do
        begin
          resource.deps.each do |dep|
            case dep
            in Ref         then dep.ready.wait
            in AnyResource then open_one(dep, resources, opening, signal).wait if resources.includes?(dep)
            end
          end
          resource.open(signal, @open_order)
          future.resolve(nil)
        rescue error
          future.reject(error)
        end
      end
      future
    end

    private def wait_hydrated(run : Run) : Nil
      exposed = run.implementation.try(&.members) || {} of String => MemberValue
      sources = run.created_derives.map(&.as(Readable))
      exposed.each_value { |value| sources << value if value.is_a?(Readable) }
      pending = sources.reject(&.hydrated?)
      return if pending.empty?
      work = Future(Nil).run { pending.each(&.wait_hydrated) }
      within_ready_timeout(work) do
        names = exposed.compact_map { |(name, value)| "#{@address}.#{name}" if value.is_a?(Readable) && !value.hydrated? }
        names + run.created_derives.reject(&.hydrated?).map { |derived| "derive #{derived.key}" }
      end
    end

    private def within_ready_timeout(work : Future(Nil), & : -> Array(String)) : Nil
      timeout = @host.ready_timeout
      if timeout && work.wait([] of AbortSignal, timeout).timed_out?
        list = yield
        waiting = list.empty? ? "" : ", waiting on #{list.join(", ")}"
        raise ChordError.new(ErrorCode::Unavailable,
          "#{@address} was not ready after #{Chord.milliseconds(timeout)} ms#{waiting} (a reference cycle across hosts?)",
          reason: "ready_timeout")
      end
      work.wait
    end

    private def init_cells(run : Run, signal : AbortSignal) : Nil
      return if run.inits.empty?
      futures = run.inits.map do |(cell, init)|
        Future(Nil).run do
          value = @host.root(signal: signal) { |ctx| init.call(ctx) }
          cell.fill(value) unless signal.aborted?
        end
      end
      Chord.await_all(futures)
    end

    private def unwind(run : Run) : Nil
      run.created_derives.each(&.detach)
      resources = run.created_resources.sort_by { |resource| -(@open_order.index(resource) || -1) }
      steps = [] of Proc(Nil)
      resources.each { |resource| steps << -> { resource.close(@open_order) } }
      run.created_refs.each { |ref| steps << -> { ref.release } }
      Chord.run_all(steps, "#{@address}: cleanup failed")
    end

    private def refresh_schemas : Nil
      schemas = {} of Source => Array(Schema::Source)
      @implementations.each_value do |installed|
        Chord.member_schemas(installed.service, installed.implementation).each do |source, list|
          (schemas[source] ||= [] of Schema::Source).concat(list)
        end
      end
      all_decls.each do |decls|
        decls.cells.each_value { |cell| cell.schemas = schemas[cell]? || [] of Schema::Source }
        decls.derives.each_value { |derived| derived.schemas = schemas[derived]? || [] of Schema::Source }
      end
    end

    private def start_runtime : Nil
      start_listeners
      @decls.tasks.each_key { |key| start_task(key, @host.code_version) }
    end

    private def start_listeners : Nil
      @decls.listeners.each do |key, decl|
        source = decl.source.call
        @subscriptions[key] = source.subscribe { |event| deliver(key, event) }
      end
    rescue error
      stop_listeners
      raise error
    end

    private def stop_listeners : Nil
      @subscriptions.each_value(&.call)
      @subscriptions.clear
    end

    private def start_task(key : String, code_version : Int32) : Nil
      fn = @decls.tasks[key]?
      return unless fn
      controller = AbortController.new
      ctx = Ctx.new(@host, [controller.signal, @call_abort.signal], "task:#{@address}:#{key}", code_version,
        @host.principal, holder: true)
      done = Future(Nil).new
      @tasks[key] = {controller, done}
      spawn { run_task(key, fn, ctx, controller, done) }
    end

    private def run_task(key : String, fn : TaskFn, ctx : Ctx, controller : AbortController, done : Future(Nil)) : Nil
      fn.call(ctx)
    rescue error
      @host.report(error) unless ctx.signal.aborted?
    ensure
      ctx.close
      @tasks.delete(key) if @tasks[key]?.try(&.[0].same?(controller))
      done.resolve(nil)
    end

    private def stop_tasks : Nil
      @tasks.each_value do |(controller, done)|
        controller.abort(ChordError.new(ErrorCode::Aborted, "task stopped"))
        @stopped << done
        done.on_settle { @stopped.delete(done); nil }
      end
      @tasks.clear
    end

    private def deliver(key : String, event : JSON::Any) : Nil
      Publish.enqueue { invoke_listener(key, event) }
    end

    private def invoke_listener(key : String, event : JSON::Any) : Nil
      decl = @decls.listeners[key]?
      return if decl.nil? || !(@status.live? || @status.activating?)
      invocation = track(Future(Nil).new)
      spawn do
        begin
          @host.root { |root| run_listener(decl, event, root) }
        rescue error
          @host.report(error)
        ensure
          invocation.resolve(nil)
        end
      end
    end

    private def run_listener(decl : ListenerDecl, event : JSON::Any, root : Ctx) : Nil
      child = root.child(self)
      begin
        decl.fn.call(event, child)
      ensure
        child.close
      end
    end

    private def admit(ctx : Ctx) : Nil
      return if @host.code_version?(ctx.code_version)
      raise ChordError.new(ErrorCode::Superseded, "code version #{ctx.code_version} is retired")
    end

    private def check_write(ctx : Ctx) : Nil
      raise Chord.invalid("read_only", "cells cannot be written while a factory runs") if @host.in_factory > 0
      ctx.check(@host)
      raise ChordError.new(ErrorCode::Aborted, "write with an aborted ctx") if ctx.signal.aborted?
      raise ChordError.new(ErrorCode::Gone, "#{@address} is disposed") if @status.disposed?
      return if ctx.root_id.starts_with?("task:")
      admit(ctx)
    end

    private def method_input(wanted : MemberDescription?, validated : MemberDescription?, name : String,
                             args : JSON::Any?) : JSON::Any?
      own = wanted.try { |member| member.method? ? member.args : nil }
      sent = own ? TypeBox::Value.clean(own, TypeBox::Value.clone(args)) : args
      expected = validated.try(&.args)
      return sent unless expected
      input = TypeBox::Value.clean(expected, TypeBox::Value.clone(sent))
      Schema.assert_valid("args", "#{@address}.#{name} args", expected, input)
      input
    end

    private def invoke(& : -> JSON::Any?) : JSON::Any?
      invocation = track(Future(Nil).new)
      begin
        yield
      ensure
        invocation.resolve(nil)
      end
    end

    private def track(invocation : Future(Nil)) : Future(Nil)
      @invocations << invocation
      invocation.on_settle { untrack(invocation) }
      invocation
    end

    private def untrack(invocation : Future(Nil)) : Nil
      @invocations.delete(invocation)
      maybe_idle if @invocations.empty?
    end

    private def maybe_idle : Nil
      return if !@refs.empty? || !@invocations.empty? || @lingering
      if @status.activating?
        background(dispose(false))
        return
      end
      return unless @status.live?
      linger = @service.try(&.linger)
      if linger.nil? || linger <= Time::Span.zero
        background(dispose(false))
        return
      end
      @lingering = true
      token = @linger_token += 1
      spawn { linger_then_dispose(linger, token) }
    end

    private def linger_then_dispose(linger : Time::Span, token : Int32) : Nil
      sleep linger
      return unless @lingering && token == @linger_token
      @lingering = false
      background(dispose(false)) if @refs.empty? && @invocations.empty? && @status.live?
    end

    private def background(disposal : Future(Nil)) : Nil
      disposal.on_settle { disposal.error.try { |error| @host.report(error) }; nil }
    end

    private def finish_dispose(was_activating : Bool, error : Exception, disposal : Future(Nil)) : Nil
      @ready.await_settled if was_activating
      @refs.to_a.each(&.gone(error))
      decls = all_decls
      stop_tasks
      stop_listeners
      @invocations.to_a.each(&.await_settled)
      registered = decls.any? { |set| !set.registrations.empty? }
      @implementations.clear
      @decls = Decls.new
      @host.registries_changed if registered
      refs = ::Set(Ref).new
      decls.each do |set|
        set.derives.each_value(&.detach)
        set.refs.each_value { |ref| refs << ref }
      end
      failure = begin
        Chord.run_all(disposal_steps(refs), "#{@address}: disposal failed")
        nil
      rescue cause
        cause
      end
      @status = ObjectStatus::Disposed
      @host.disposed(self)
      failure ? disposal.reject(failure) : disposal.resolve(nil)
    end

    private def disposal_steps(refs : ::Set(Ref)) : Array(Proc(Nil))
      steps = [-> { @stopped.to_a.each(&.await_settled); nil }]
      @open_order.reverse.each { |resource| steps << -> { resource.close(@open_order) } }
      refs.each { |ref| steps << -> { ref.release } }
      steps
    end
  end

  def self.member_schemas(service : Service, implementation : Implementation) : Hash(Source, Array(Schema::Source))
    result = {} of Source => Array(Schema::Source)
    contract = service.contract
    return result unless contract.remote?
    members = contract.description.variants[implementation.variant || LOCAL_VARIANT]?
    return result unless members
    members.each do |name, description|
      source = implementation[name]?
      schema = description.schema
      next unless description.state? && source.is_a?(Source) && schema
      (result[source] ||= [] of Schema::Source) << schema
    end
    result
  end

  def self.validate_implementation(service : Service, implementation : Implementation) : Nil
    contract = service.contract
    variants = contract.description.variants
    members = if contract.remote?
                variant = implementation.variant
                found = variant ? variants[variant]? : nil
                raise invalid_implementation(contract, "unknown variant #{variant || "undefined"}") unless found
                implementation.keys.each do |key|
                  raise invalid_implementation(contract, "#{key} is not in variant #{variant}") unless found.has_key?(key)
                end
                found
              else
                variants[LOCAL_VARIANT]? || {} of String => MemberDescription
              end
    members.each do |name, description|
      value = implementation[name]?
      raise invalid_implementation(contract, "#{name} must be a method") if description.method? && !value.is_a?(MethodFn)
      if description.state? && !value.is_a?(Readable)
        raise invalid_implementation(contract, "#{name} must be a cell, a derivation or a held object's state member")
      end
      raise invalid_implementation(contract, "#{name} is missing") if description.opaque? && value.nil?
    end
  end

  private def self.invalid_implementation(contract : Contract, message : String) : ChordError
    invalid("implementation", "#{contract.name}: #{message}")
  end
end
