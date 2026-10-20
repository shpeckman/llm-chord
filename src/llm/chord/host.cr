# src/llm/chord/host.cr
module LLM::Chord
  class Route
    getter authorize : Proc(JSON::Any, String, Bool)
    getter resolve : Proc(String, Link)
    getter principal : Proc(String, JSON::Any)

    def initialize(*, authorize : Proc(JSON::Any, String, A), resolve : Proc(String, L), principal : Proc(String, P)) forall A, L, P
      @authorize = Route.authorizer(authorize)
      @resolve = Route.resolver(resolve)
      @principal = Route.stamper(principal)
    end

    protected def self.authorizer(authorize : Proc(JSON::Any, String, A)) : Proc(JSON::Any, String, Bool) forall A
      ->(principal : JSON::Any, host : String) { authorize.call(principal, host) == true }
    end

    protected def self.resolver(resolve : Proc(String, L)) : Proc(String, Link) forall L
      ->(host : String) { resolve.call(host).as(Link) }
    end

    protected def self.stamper(principal : Proc(String, P)) : Proc(String, JSON::Any) forall P
      ->(host : String) { Chord.json_value(principal.call(host)) }
    end
  end

  record Upstream, link : Link, principal : JSON::Any, options : LinkOptions

  alias PluginRef = Facet | String

  record CodeVersionState, id : Int32, services : Hash(String, Service), tables : Hash(String, RegistryTable),
    roots : Hash(String, Int32), abort : AbortController

  def self.upstream(link : Link, *, principal, **options) : Upstream
    Upstream.new(link, json_value(principal), LinkOptions.new(**options))
  end

  class Host
    EMPTY_TABLE = RegistryTable.new

    getter name : String
    getter? dev : Bool
    getter principal : JSON::Any
    getter ready_timeout : Time::Span?
    getter kind : PeerKind
    getter connections = ::Set(Connection).new
    getter upstream : Connection? = nil
    protected property in_factory = 0
    protected getter source_options : SourceOptions { SourceOptions.new(@dev, ->(error : Exception) { report(error) }) }
    protected getter objects = {} of String => ObjectImpl
    @dying = {} of String => ObjectImpl
    protected getter facets = {} of String => Facet
    @facet_runs = {} of String => AbortController
    protected getter host_objects = {} of String => Ref
    protected getter code_versions = {} of Int32 => CodeVersionState
    protected property current : CodeVersionState
    protected property previous : CodeVersionState? = nil
    protected property pending : CodeVersionState? = nil
    protected property gating : ::Set(String)? = nil
    protected property reloading = false
    protected property remote_modules = {} of String => Array(String)
    protected property remote_removed = {} of String => Array(String)
    protected getter failed : Exception? = nil
    @order = {} of String => Hash(String, Int32)
    @subscribers = {} of String => Listeners(TableListener)
    @bindings = {} of String => RemoteBinding
    @lingering = {} of String => RemoteBinding
    @routes = {} of String => Route
    @local = ::Set(String).new
    @foreign = {} of String => ::Set(Connection)
    @root_links = {} of String => ::Set(Connection)
    @touches = {} of String => ::Set(ObjectImpl)
    @retirement_watchers = ::Set(Proc(Nil)).new
    @deferred_hellos = {} of Connection => Int32
    @reload_waiters = [] of Proc(Nil)
    @child_reloads : ChildReloads
    @retire_allowed = 0
    @origin_seq = 0
    @root_seq = 0_i64
    @code_version_seq = 1
    @incarnation : String = Random.new.hex(3)
    @principal_key : Proc(JSON::Any, String)
    @self_key : String
    @on_error : Reporter
    @linger_types : Hash(String, Time::Span)
    @linger_cap : Int32
    @loader : Proc(Array(String), Array(Facet))?

    def initialize(*, self principal, @name : String = "host", principal_key : Proc(JSON::Any, String)? = nil,
                   @dev : Bool = false, on_error = nil, @ready_timeout : Time::Span? = 60.seconds,
                   @kind : PeerKind = PeerKind::Host, upstream : Upstream? = nil,
                   linger : Hash(String, Time::Span)? = nil, linger_cap : Int32 = 4,
                   loader : Proc(Array(String), Array(Facet))? = nil)
      @principal = Chord.json_value(principal)
      @principal_key = principal_key || Host.canonical_key
      @self_key = @principal_key.call(@principal)
      @on_error = Host.reporter(on_error)
      @linger_types = linger || {} of String => Time::Span
      @linger_cap = linger_cap
      @loader = loader
      @current = CodeVersionState.new(1, {} of String => Service, {} of String => RegistryTable,
        {} of String => Int32, AbortController.new)
      @code_versions[1] = @current
      @child_reloads = ChildReloads.new(self)
      upstream.try { |link| connect(link.link, principal: link.principal, options: link.options) }
    end

    def code_version : Int32
      @current.id
    end

    def previous_code_version : Int32?
      @previous.try(&.id)
    end

    protected def has_code_version?(code_version : Int32) : Bool
      @code_versions.has_key?(code_version)
    end

    protected def retained_code_versions : Array(Tuple(Int32, Hash(String, Service)))
      result = [] of Tuple(Int32, Hash(String, Service))
      @code_versions.each { |(id, state)| result << {id, state.services} }
      result << {@pending.id, @pending.services} if @pending
      result
    end

    protected def pending_code_version : Int32?
      @pending.try(&.id)
    end

    protected def next_code_version_id(given : Int32? = nil) : Int32
      if given && given <= @current.id
        raise ArgumentError.new("code version #{given} is not newer than #{@current.id}")
      end
      @code_version_seq = given || @code_version_seq + 1
      @code_version_seq
    end

    protected def peek_next_code_version : Int32
      @code_version_seq + 1
    end

    def serve(contract : Contract, *, lifetime : Lifetime = Lifetime::Referenced, linger : Time::Span? = nil,
              accepts : Accepts? = nil, &factory : JSON::Any, JSON::Any, ObjectScope -> Implementation) : Nil
      raise ArgumentError.new("host.serve during a reload; serve from a facet passed to reload()") if @reloading
      service = Service.new(contract, factory, lifetime, linger, accepts, "")
      serve_into(@current.services, service)
      start_host_object(service) if service.host_lifetime?
    end

    def install(facet : Facet, await_host_objects : Bool = true) : Nil
      refs = install_facet(facet)
      Host.wait_ready(refs) if await_host_objects
    end

    def load(facets : Enumerable(Facet), await_host_objects : Bool = true) : Nil
      refs = [] of Ref
      facets.each { |facet| refs.concat(install_facet(facet)) }
      Host.wait_ready(refs) if await_host_objects
    end

    def ready : Nil
      Host.wait_ready(@host_objects.values)
    end

    def get(type : Contract, input = nil, principal = nil, signal : AbortSignal? = nil, state : Bool = true) : Ref
      ref = acquire(type, input, principal.nil? ? nil : Chord.json_value(principal), RefOwner::External, state: state)
      Chord.await_ready(ref, signal ? [signal] : [] of AbortSignal, @ready_timeout)
      ref
    end

    def hold(type : Contract, input = nil, principal = nil, state : Bool = true) : Ref
      acquire(type, input, principal.nil? ? nil : Chord.json_value(principal), RefOwner::External, state: state)
    end

    def root(principal = nil, signal : AbortSignal? = nil, code_version : Int32? = nil, &)
      @root_seq += 1
      root_id = "#{@name}##{@incarnation}:#{@root_seq}"
      @local << root_id
      join_root(root_id, code_version || @code_version, principal.nil? ? nil : Chord.json_value(principal), signal) do |ctx|
        yield ctx
      end
    end

    def registry(registry : Registry(V)) : RegistryView(V) forall V
      RegistryView(V).new(self, registry)
    end

    def invalidate_principal(&match : JSON::Any -> Bool) : Nil
      invalidate(match, nil)
    end

    def invalidate_principal(pattern) : Nil
      fields = Chord.json_value(pattern)
      invalidate(Host.pattern_matcher(fields), fields)
    end

    def accept(link : Link, *, principal, kind : PeerKind = PeerKind::Client, name : String? = nil, restamp = nil,
               max_calls : Int32? = nil, options : LinkOptions? = nil, **link_options) : Nil
      raise ArgumentError.new("accepting a host link needs its name") if kind.host? && name.nil?
      origin = kind.client? ? "#{@incarnation}:#{@origin_seq += 1}" : nil
      add_connection(Connection.new(self, link, Role::Downstream, Chord.json_value(principal),
        Peer.new(kind, kind.host? ? name : nil), options || LinkOptions.new(**link_options), origin,
        Host.restamper(restamp), max_calls))
    end

    def connect(link : Link, *, principal, options : LinkOptions? = nil, **link_options) : Nil
      @upstream.try { |previous| previous.link.close("replaced") if previous.open? }
      connection = add_connection(Connection.new(self, link, Role::Upstream, Chord.json_value(principal),
        Peer.new(PeerKind::Host, nil), options || LinkOptions.new(**link_options)))
      @upstream = connection
      @bindings.values.each do |binding|
        connection.hold(binding, binding.applied?) if binding.hold.nil? && !binding.ended?
      end
    end

    def route(prefix : String, route : Route) : Nil
      @routes[prefix] = route
    end

    def close : Nil
      @lingering.values.each(&.close)
      @host_objects.clear
      @facet_runs.keys.each { |name| facet_run_changed(name, nil) }
      begin
        Host.dispose_holders_first(@objects.values, ChordError.new(ErrorCode::Gone, "host #{@name} closed"),
          "host close: disposal failed")
      ensure
        @connections.to_a.each(&.link.close("host closed"))
      end
    end

    def report(error : Exception) : Nil
      @on_error.call(error)
    end

    protected def resolve(plugins : Array(PluginRef)) : Array(Facet)
      modules = plugins.select(String)
      loaded = [] of Facet
      unless modules.empty?
        raise ArgumentError.new("loading modules needs create_host({ loader })") if @loader.nil?
        loaded = @loader.not_nil!.call(modules)
      end
      index = 0
      plugins.map do |ref|
        if ref.is_a?(Facet)
          ref
        else
          facet = loaded[index]
          index += 1
          facet
        end
      end
    end

    def reload(facets : Enumerable(Facet), options : ReloadOptions = ReloadOptions.new) : ReloadReport
      if !@kind.client? && !@upstream.nil?
        raise ChordError.new(ErrorCode::Unavailable, "reloads are coordinated by the server", reason: "not_coordinator")
      end
      children = @connections.any? { |c| c.role.downstream? && c.peer.kind.host? }
      if children || !options.remote.nil? || !options.remote_remove.nil?
        Chord.run_cluster_reload(self, facets.to_a, options)
      else
        Chord.run_reload(self, facets.to_a, options)
      end
    end

    protected def remember_remote_modules(remote : Hash(String, Array(String))?, remove : Hash(String, Array(String))?) : Nil
      prefixes = ::Set(String).new
      remote.try &.each_key { |prefix| prefixes << prefix }
      remove.try &.each_key { |prefix| prefixes << prefix }
      prefixes.each do |prefix|
        modules = remote.try(&.[prefix]?) || [] of String
        removed = remove.try(&.[prefix]?) || [] of String
        merged = (@remote_modules[prefix]? || [] of String).to_set
        modules.each { |m| merged << m }
        @remote_modules[prefix] = merged.to_a.reject { |m| removed.includes?(m) }
        removed_merged = (@remote_removed[prefix]? || [] of String).to_set
        removed.each { |m| removed_merged << m }
        @remote_removed[prefix] = removed_merged.to_a.reject { |m| modules.includes?(m) }
      end
    end

    protected def retirable? : Bool
      previous = @previous
      return false if previous.nil? || !previous.roots.empty?
      @kind.client? || @upstream.nil? || previous.id <= @retire_allowed
    end

    protected def retire : Nil
      previous = @previous
      return unless previous
      @previous = nil
      @code_versions.delete(previous.id)
      @objects.values.each { |object| retire_implementation(object, previous.id) }
      @connections.each do |connection|
        connection.send(Frame.build("retire", codeVersion: previous.id)) if connection.role.downstream? && connection.peer.kind.host?
      end
      retirement_changed
    end

    private def maybe_retire : Nil
      retire if retirable?
    end

    protected def watch_retirement(&watcher : ->) : Proc(Nil)
      @retirement_watchers << watcher
      -> { @retirement_watchers.delete(watcher); nil }
    end

    private def retirement_changed : Nil
      @retirement_watchers.to_a.each(&.call)
    end

    protected def announce_retired(connection : Connection) : Nil
      retired = (@previous || @current).id - 1
      connection.send(Frame.build("retire", codeVersion: retired)) if retired > 0
    end

    protected def retire_implementation(object : ObjectImpl, code_version : Int32) : Nil
      installed = object.implementations.delete(code_version)
      return if installed.nil? || installed.decls.same?(object.decls)
      kept = object.all_decls
      refs = ::Set(Ref).new
      resources = ::Set(AnyResource).new
      derives = ::Set(Derived).new
      kept.each do |decls|
        decls.refs.each_value { |ref| refs << ref }
        decls.resources.each_value { |resource| resources << resource }
        decls.derives.each_value { |derived| derives << derived }
      end
      installed.decls.derives.each_value { |derived| derived.detach unless derives.includes?(derived) }
      closing = installed.decls.resources.values.reject { |resource| resources.includes?(resource) }
        .sort_by { |resource| -(object.open_order.index(resource) || -1) }
      releasing = installed.decls.refs.values.reject { |ref| refs.includes?(ref) }
      object.refresh_schemas
      steps = [] of Proc(Nil)
      closing.each { |resource| steps << -> { resource.close(object.open_order) } }
      releasing.each { |ref| steps << -> { ref.release } }
      begin
        Chord.run_all(steps, "#{object.address}: retiring code version #{code_version} failed")
      rescue error
        report(error)
      end
    end

    protected def fail(error : Exception) : Nil
      @failed ||= error
      report(error)
    end

    protected def reload_ended : Nil
      @reloading = false
      deferred = @deferred_hellos.to_a
      @deferred_hellos.clear
      deferred.each { |(connection, version)| peer_hello(connection, version) if connection.open? }
      @reload_waiters.each(&.call)
      @reload_waiters.clear
      maybe_retire
    end

    protected def when_reload_ended : Future(Nil)
      future = Future(Nil).new
      unless @reloading
        future.resolve(nil)
        return future
      end
      @reload_waiters << -> { future.resolve(nil); nil }
      future
    end

    protected def service(type_name : String) : Service?
      @current.services[type_name]? || @pending.try(&.services[type_name]?)
    end

    protected def binding_service(type_name : String, candidate : Bool) : Service?
      (candidate ? @pending.try(&.services[type_name]?) : nil) || service(type_name)
    end

    protected def serve_into(services : Hash(String, Service), service : Service) : Nil
      contract = service.contract
      raise ArgumentError.new("#{contract.name} is already served") if services.has_key?(contract.name)
      placement = contract.description.host
      if placement && !placement.placed_on?(@name)
        raise ArgumentError.new("#{contract.name} is declared for #{placement.text}, but #{@name} serves it")
      end
      services[contract.name] = service
    end

    protected def join_root(root_id : String, code_version : Int32, principal : JSON::Any? = nil,
                            signal : AbortSignal? = nil, from : Connection? = nil, &)
      state = @code_versions[code_version]?
      unless state
        @local.delete(root_id)
        raise ChordError.new(ErrorCode::Superseded, "code version #{code_version} is not retained by #{@name}")
      end
      if from && !@local.includes?(root_id)
        (@foreign[root_id] ||= ::Set(Connection).new) << from
      end
      state.roots[root_id] = (state.roots[root_id]? || 0) + 1
      signals = signal ? [signal, state.abort.signal] : [state.abort.signal]
      ctx = Ctx.new(self, signals, root_id, code_version, principal || @principal)
      begin
        yield ctx
      ensure
        ctx.close
        count = (state.roots[root_id]? || 1) - 1
        if count > 0
          state.roots[root_id] = count
        else
          state.roots.delete(root_id)
          unless @foreign.has_key?(root_id)
            end_root(root_id)
            maybe_retire
            retirement_changed
          end
        end
      end
    end

    protected def root_sent(root_id : String, connection : Connection) : Nil
      (@root_links[root_id] ||= ::Set(Connection).new) << connection
    end

    protected def foreign_root_ended(root_id : String, from : Connection) : Nil
      links = @foreign[root_id]?
      return unless links && links.delete(from) && links.empty?
      if @code_versions.values.any? { |state| state.roots.has_key?(root_id) }
        @foreign.delete(root_id)
      else
        end_root(root_id)
      end
    end

    protected def touch(root_id : String, object : ObjectImpl) : Nil
      (@touches[root_id] ||= ::Set(ObjectImpl).new) << object
    end

    protected def acquire(type : Contract, input, principal : JSON::Any?, owner : RefOwner, from : ObjectImpl? = nil,
                          state : Bool = true, candidate : Bool = false) : Ref
      raw = Chord.json_input(input)
      if elsewhere = elsewhere(type, raw)
        return acquire_remote(type, elsewhere[0], elsewhere[1], principal, owner, state)
      end
      service = binding_service(type.name, candidate) || raise unknown_type(type.name)
      Chord.bind(service.contract, service.accepts, type)
      address, normalized, chosen = locate(service, raw, principal || @principal)
      placement = service.contract.description.host
      if placement && (at = placement.resolve(type.name, normalized)) != @name
        raise Chord.invalid("placement", "#{type.name} with this input lives on #{at}, not #{@name}")
      end
      object = @objects[address]?
      if from && object && (object.same?(from) || Host.reaches?(object, from))
        raise Chord.invalid("cycle", "#{from.address} -> #{address} would create a ref cycle")
      end
      if object.nil?
        if @gating && @gating.includes?(type.name)
          raise ChordError.new(ErrorCode::UpgradeConflict, "#{type.name} is being upgraded; retry", reason: "gate")
        end
        object = create_object(service, type, address, normalized, chosen)
      end
      ref = LocalRef.new(object, type, owner)
      object.add_ref(ref)
      ref
    end

    protected def address_of(type : Contract, input, principal : JSON::Any, candidate : Bool = false) : String
      raw = Chord.json_input(input)
      if elsewhere = elsewhere(type, raw)
        return remote_key(type, elsewhere[1], principal)
      end
      service = binding_service(type.name, candidate) || raise unknown_type(type.name)
      locate(service, raw, principal)[0]
    end

    protected def forget(object : ObjectImpl) : Nil
      @objects.delete(object.address) if @objects[object.address]?.try(&.same?(object))
      @dying[object.address] = object if object.status.disposing?
    end

    protected def disposed(object : ObjectImpl) : Nil
      @dying.delete(object.address) if @dying[object.address]?.try(&.same?(object))
    end

    protected def registry_table(registry : AnyRegistry, ctx : Ctx?) : RegistryTable
      state = if ctx
                @code_versions[ctx.code_version]? ||
                  raise ChordError.new(ErrorCode::Superseded, "code version #{ctx.code_version} is retired")
              else
                @current
              end
      state.tables[registry.name]? || EMPTY_TABLE
    end

    protected def subscribe_registry(name : String, listener : TableListener) : Proc(Nil)
      listeners = @subscribers[name] ||= Listeners(TableListener).new
      id = listeners.add(listener)
      listener.call(@current.tables[name]? || EMPTY_TABLE, @current.id)
      listeners.remover(id)
    end

    protected def check_registrations(object : ObjectImpl, decls : Decls) : Nil
      return if decls.registrations.empty?
      entries = live_decls.reject { |(other, _)| other.same?(object) }
      entries << {object, decls}
      build_tables(entries)
    end

    protected def registries_changed(including : ObjectImpl? = nil) : Nil
      entries = live_decls.reject { |(object, _)| object.same?(including) }
      entries << {including, including.decls} if including
      install_tables(@current, build_tables(entries))
    end

    protected def peer_hello(connection : Connection, code_version : Int32) : Nil
      if code_version > @current.id
        report(ChordError.new(ErrorCode::Invalid, "#{connection.name} runs code version #{code_version}, ahead of #{@current.id}"))
        connection.link.close("code version ahead of parent")
        return
      end
      if @reloading
        connection.peer_code_version = code_version
        connection.fenced_code_versions << code_version if code_version < @current.id
        @deferred_hellos[connection] = code_version
        return
      end
      if code_version == @current.id
        connection.mark_synced(code_version)
        announce_retired(connection)
        return
      end
      connection.peer_code_version = code_version
      connection.fenced_code_versions << code_version
      spawn do
        begin
          Chord.reconcile_child(self, connection)
        rescue error
          report(error)
          connection.link.close("reconciliation failed")
        end
      end
    end

    protected def allow_retire(code_version : Int32) : Nil
      @retire_allowed = Math.max(@retire_allowed, code_version)
      maybe_retire
      retirement_changed
    end

    protected def on_reload_frame(connection : Connection, frame : Frame) : Nil
      @child_reloads.handle(connection, frame)
    end

    protected def connection_closed(connection : Connection) : Nil
      @connections.delete(connection)
      @deferred_hellos.delete(connection)
      @foreign.to_a.each { |(root_id, links)| foreign_root_ended(root_id, connection) if links.includes?(connection) }
      @root_links.each_value(&.delete(connection))
      if @upstream.same?(connection)
        @upstream = nil
        @child_reloads.parent_lost
      end
    end

    protected def binding_idle(binding : RemoteBinding) : Nil
      span = @linger_types[binding.contract.name]?
      if span.nil? || span <= Time::Span.zero || binding.ended? || !binding.applied? || @linger_cap <= 0
        binding.close
        return
      end
      token = binding.linger_token += 1
      spawn { linger_then_close(binding, span, token) }
      @lingering[binding.key] = binding
      @lingering.values.each do |oldest|
        break if @lingering.size <= @linger_cap
        oldest.close
      end
    end

    protected def forget_binding(binding : RemoteBinding) : Nil
      @bindings.delete(binding.key) if @bindings[binding.key]?.same?(binding)
      @lingering.delete(binding.key) if @lingering[binding.key]?.same?(binding)
    end

    protected def relay(relay : RelayRef) : Nil
      frame = relay.frame
      at = frame.string("at")
      token = Chord.contract_from_description(frame["token"])
      placement = token.description.host
      unless placement && placement.resolve(token.name, frame["input"]) == at
        raise Chord.invalid("placement", "#{token.name} with this input does not live on #{at}")
      end
      route = route_for(at)
      unless route
        raise child_named(at) ? ChordError.new(ErrorCode::Forbidden, "no route authorizes #{at}") : ChordError.new(ErrorCode::Unavailable, "no route to #{at}")
      end
      down = resolve_route(route, at, relay.principal, relay)
      return unless relay.current?
      relay.open(down)
    end

    private def end_root(root_id : String) : Nil
      @local.delete(root_id)
      @foreign.delete(root_id)
      (@touches[root_id]? || [] of ObjectImpl).to_a.each(&.root_ended(root_id))
      @touches.delete(root_id)
      @root_links.delete(root_id).try &.each(&.send(Frame.build("root_end", rootId: root_id)))
    end

    private def add_connection(connection : Connection) : Connection
      @connections << connection if connection.open?
      connection
    end

    protected def facet_api(facet : String, signal : AbortSignal, added : Array(Service), services : Hash(String, Service)) : FacetApi
      FacetApi.new(self, facet, signal, ->(service : Service) { serve_into(services, service); added << service; nil })
    end

    private def install_facet(facet : Facet) : Array(Ref)
      raise ArgumentError.new("facet #{facet.name} is already installed") if @facets.has_key?(facet.name)
      added = [] of Service
      run = AbortController.new
      begin
        facet.setup.call(facet_api(facet.name, run.signal, added, @current.services))
      rescue error
        run.abort(error)
        raise error
      end
      @facets[facet.name] = facet
      facet_run_changed(facet.name, run)
      added.select(&.host_lifetime?).map { |service| start_host_object(service) }
    end

    protected def facet_run_changed(name : String, run : AbortController?) : Nil
      replaced = @facet_runs[name]?
      run ? (@facet_runs[name] = run) : @facet_runs.delete(name)
      replaced.abort(ChordError.new(ErrorCode::Gone, "facet #{name} was replaced or removed")) if replaced && !replaced.same?(run)
    end

    protected def start_host_object(service : Service) : Ref
      ref = acquire(service.contract, nil, nil, RefOwner::Host)
      @host_objects[service.contract.name] = ref
      ready = ref.ready
      ready.on_settle { ready.error.try { |error| report(error) }; nil }
      ref
    end

    private def create_object(service : Service, type : Contract, address : String, normalized : JSON::Any,
                              principal : JSON::Any) : ObjectImpl
      dying = @dying[address]?
      @dying.delete(address) if dying && dying.status.disposed?
      object = ObjectImpl.new(self, address, type.name, normalized, principal, service.host_lifetime?)
      @objects[address] = object
      object.start(dying && dying.status.disposing? ? dying.dispose(false) : nil)
      object
    end

    private def elsewhere(type : Contract, input : JSON::Any?) : Tuple(String, JSON::Any)?
      placement = type.description.host
      return unless type.remote? && placement
      normalized = Schema.normalize(type.input, input, "#{type.name} input").not_nil!
      at = placement.resolve(type.name, normalized)
      at == @name ? nil : {at, normalized}
    end

    private def acquire_remote(type : Contract, at : String, input : JSON::Any, principal : JSON::Any?, owner : RefOwner,
                               state : Bool) : Ref
      forwarded = principal.nil? || own_principal?(principal) ? nil : principal
      key = remote_key(type, input, forwarded || @principal)
      binding = @bindings[key]?
      fresh = binding.nil? || binding.ended?
      if binding.nil? || binding.ended?
        binding = RemoteBinding.new(self, key, type, at, input, forwarded)
        @bindings[key] = binding
      end
      ref = RemoteRef.new(binding, owner, state)
      @lingering.delete(key)
      binding.add_view(ref)
      hold(binding) if fresh
      ref
    end

    private def hold(binding : RemoteBinding) : Nil
      if upstream = @upstream
        upstream.hold(binding, false)
      elsif direct = child_named(binding.at)
        spawn { hold_when_synced(binding) { direct.when_synced; direct } }
      elsif route = route_for(binding.at)
        spawn { hold_when_synced(binding) { resolve_route(route, binding.at, binding.principal || @principal, nil) } }
      else
        binding.gone(ChordError.new(ErrorCode::Unavailable, "no route to #{binding.at}"))
      end
    end

    private def hold_when_synced(binding : RemoteBinding, & : -> Connection) : Nil
      target = yield
      target.hold(binding, false) if !binding.ended? && binding.hold.nil?
    rescue error
      binding.gone(error)
    end

    private def route_for(host_name : String) : Route?
      best = nil.as(Tuple(String, Route)?)
      @routes.each do |prefix, route|
        best = {prefix, route} if host_name.starts_with?(prefix) && (best.nil? || prefix.size > best[0].size)
      end
      best.try(&.[1])
    end

    private def child_named(name : String) : Connection?
      @connections.find { |connection| connection.open? && connection.role.downstream? && connection.peer.kind.host? && connection.peer.name == name }
    end

    private def resolve_route(route : Route, host_name : String, principal : JSON::Any, relay : RelayRef?) : Connection
      refuse = ChordError.new(ErrorCode::Forbidden, "#{host_name} refused for this principal")
      revoked = ChordError.new(ErrorCode::Gone, "principal invalidated while resolving")
      raise refuse unless route.authorize.call(principal, host_name)
      raise revoked if relay && !relay.current?
      link = route.resolve.call(host_name)
      raise revoked if relay && !relay.current?
      raise refuse unless route.authorize.call(principal, host_name)
      raise revoked if relay && !relay.current?
      connection = @connections.find(&.link.same?(link)) ||
                   add_connection(Connection.new(self, link, Role::Downstream, route.principal.call(host_name),
                     Peer.new(PeerKind::Host, host_name), LinkOptions.new))
      connection.when_synced
      raise revoked if relay && !relay.current?
      connection
    end

    private def locate(service : Service, input : JSON::Any?, principal : JSON::Any) : Tuple(String, JSON::Any, JSON::Any)
      contract = service.contract
      normalized = Schema.normalize(contract.input, input, "#{contract.name} input").not_nil!
      identity = Schema.canonical_identity(contract.input, normalized)
      if service.host_lifetime?
        empty = Schema.normalize(contract.input, nil, "#{contract.name} input")
        unless identity == Schema.canonical_identity(contract.input, empty)
          raise Chord.invalid("input", %(#{contract.name} has lifetime "host": its one object has the empty input))
        end
        principal = @principal
      end
      {"#{contract.name}\u0000#{identity}\u0000#{principal_part(principal)}", normalized, principal}
    end

    private def remote_key(type : Contract, normalized : JSON::Any, principal : JSON::Any) : String
      identity = Schema.canonical_identity(type.input, normalized)
      "@#{type.name}\u0000#{identity}\u0000#{principal_part(principal)}\u0000#{type.fingerprint}"
    end

    private def own_principal?(principal : JSON::Any) : Bool
      principal == @principal || @principal_key.call(principal) == @self_key
    end

    private def principal_part(principal : JSON::Any) : String
      own_principal?(principal) ? "host" : "p:#{@principal_key.call(principal)}"
    end

    private def unknown_type(type_name : String) : ChordError
      ChordError.new(ErrorCode::Unavailable, "#{type_name} is not served by #{@name}", reason: "unknown_type")
    end

    protected def live_decls(candidates : Bool = false) : Array(Tuple(ObjectImpl, Decls))
      @objects.values.select(&.status.live?).reject { |object| !candidates && object.deferred_runtime }.map { |object| {object, object.decls} }
    end

    protected def build_tables(entries : Array(Tuple(ObjectImpl, Decls))) : Hash(String, RegistryTable)
      by_registry = {} of String => Hash(String, Tuple(RegistryEntry, ObjectImpl))
      entries.each do |(object, decls)|
        decls.registrations.each_value do |registration|
          registry = registration.registry
          table = by_registry[registry.name] ||= {} of String => Tuple(RegistryEntry, ObjectImpl)
          existing = table[registration.key]?
          if existing && !existing[1].same?(object) && registry.conflict.error?
            raise Chord.invalid("registry_conflict",
              "#{registry.name}: #{registration.key} registered by #{existing[1].address} and #{object.address}")
          end
          table[registration.key] = {registration.entry, object}
          order = @order[registry.name] ||= {} of String => Int32
          order[registration.key] = order.size unless order.has_key?(registration.key)
        end
      end
      tables = {} of String => RegistryTable
      by_registry.each do |name, table|
        order = @order[name]
        sorted = RegistryTable.new
        table.to_a.sort_by! { |(key, _)| order[key] }.each { |(key, value)| sorted[key] = value[0] }
        tables[name] = sorted
      end
      tables
    end

    protected def install_tables(code_version : CodeVersionState, tables : Hash(String, RegistryTable), all : Bool = false) : Nil
      before = code_version.tables
      code_version.tables = tables
      return unless code_version.id == @current.id
      @subscribers.each do |name, listeners|
        following = tables[name]? || EMPTY_TABLE
        next if !all && Host.same_table?(before[name]? || EMPTY_TABLE, following)
        current = listeners.snapshot
        version = code_version.id
        Publish.enqueue { notify_table(current, following, version) }
      end
    end

    private def notify_table(listeners, table : RegistryTable, code_version : Int32) : Nil
      listeners.each do |(_, listener)|
        listener.call(table, code_version)
      rescue error
        report(error)
      end
    end

    private def invalidate(matches : Proc(JSON::Any, Bool), pattern : JSON::Any?) : Nil
      @connections.to_a.each do |connection|
        next unless connection.role.downstream? && matches.call(connection.principal)
        connection.revoke(connection.restamp.try &.call(connection.principal))
      end
      if pattern
        @connections.each do |connection|
          next unless connection.role.downstream? && connection.peer.kind.host?
          connection.send(Frame.build("invalidate", pattern: pattern))
        end
      end
      reason = ChordError.new(ErrorCode::Gone, "principal invalidated")
      matching = @objects.values.select { |object| !own_principal?(object.principal) && matches.call(object.principal) }
      Host.dispose_holders_first(matching, reason, "invalidatePrincipal: disposal failed")
    end

    private def linger_then_close(binding : RemoteBinding, span : Time::Span, token : Int32) : Nil
      sleep span
      binding.close if binding.linger_token == token && binding.views.empty? && !binding.ended?
    end

    protected def self.wait_ready(refs : Enumerable(Ref)) : Nil
      Chord.await_all(refs.map(&.ready))
    end

    protected def self.canonical_key : Proc(JSON::Any, String)
      ->(principal : JSON::Any) { Schema.canonical_json(principal) }
    end

    protected def self.reporter(_on_error : Nil) : Reporter
      ->(error : Exception) { STDERR.puts "chord: #{error.inspect_with_backtrace}"; nil }
    end

    protected def self.reporter(on_error : Proc(Exception, U)) : Reporter forall U
      ->(error : Exception) { on_error.call(error); nil }
    end

    protected def self.restamper(_restamp : Nil) : Proc(JSON::Any, JSON::Any?)?
      nil
    end

    protected def self.restamper(restamp : Proc(JSON::Any, U)) : Proc(JSON::Any, JSON::Any?)? forall U
      ->(principal : JSON::Any) : JSON::Any? { Host.optional_json(restamp.call(principal)) }
    end

    protected def self.optional_json(_value : Nil) : JSON::Any?
      nil
    end

    protected def self.optional_json(value) : JSON::Any?
      Chord.json_value(value)
    end

    protected def self.pattern_matcher(pattern : JSON::Any) : Proc(JSON::Any, Bool)
      ->(principal : JSON::Any) { matches_pattern?(pattern, principal) }
    end

    protected def self.matches_pattern?(pattern : JSON::Any, principal : JSON::Any) : Bool
      fields = principal.as_h?
      return false unless fields
      pattern.as_h.all? { |key, value| Schema.deep_equal?(fields[key]?, value) }
    end

    protected def self.same_table?(left : RegistryTable, right : RegistryTable) : Bool
      return false unless left.size == right.size
      left.zip(right).all? { |(a_key, a_entry), (b_key, b_entry)| a_key == b_key && a_entry.same?(b_entry) }
    end

    protected def self.reaches?(from : ObjectImpl, to : ObjectImpl) : Bool
      seen = ::Set(ObjectImpl).new
      stack = [from]
      while object = stack.pop?
        return true if object.same?(to)
        next if seen.includes?(object)
        seen << object
        object.all_decls.each { |decls| decls.refs.each_value { |ref| ref.object.try { |held| stack << held } } }
      end
      false
    end

    protected def self.dispose_holders_first(objects : Array(ObjectImpl), reason : Exception, message : String) : Nil
      remaining = objects.to_set
      held = objects.to_h { |object| {object, held_by(object)} }
      errors = [] of Exception
      until remaining.empty?
        targets = ::Set(ObjectImpl).new
        remaining.each { |object| targets.concat(held[object]) }
        wave = remaining.reject { |object| targets.includes?(object) }
        wave = remaining.to_a if wave.empty?
        wave.each { |object| remaining.delete(object) }
        disposals = wave.map(&.dispose(true, reason))
        disposals.each(&.await_settled)
        disposals.each { |disposal| disposal.error.try { |error| errors << error } }
      end
      raise errors[0] if errors.size == 1
      raise AggregateError.new(errors, message) if errors.size > 1
    end

    private def self.held_by(object : ObjectImpl) : ::Set(ObjectImpl)
      result = ::Set(ObjectImpl).new
      object.all_decls.each { |decls| decls.refs.each_value { |ref| ref.object.try { |held| result << held } } }
      result
    end
  end

  macro create_host(**options)
    ::LLM::Chord::Host.new({{options.double_splat}})
  end
end
