# src/llm/chord/host.cr
module LLM::Chord
  class Host
    EMPTY_TABLE = RegistryTable.new

    getter name : String
    getter? dev : Bool
    getter principal : JSON::Any
    getter ready_timeout : Time::Span?
    getter code_version = 1
    protected property in_factory = 0
    protected getter source_options : SourceOptions { SourceOptions.new(@dev, ->(error : Exception) { report(error) }) }
    @objects = {} of String => ObjectImpl
    @dying = {} of String => ObjectImpl
    @facets = {} of String => Facet
    @facet_runs = {} of String => AbortController
    @host_objects = {} of String => Ref
    @services = {} of String => Service
    @tables = {} of String => RegistryTable
    @order = {} of String => Hash(String, Int32)
    @subscribers = {} of String => Listeners(TableListener)
    @root_seq = 0_i64
    @incarnation : String = Random.new.hex(3)
    @principal_key : Proc(JSON::Any, String)
    @self_key : String
    @on_error : Reporter

    def initialize(*, self principal, @name : String = "host", principal_key : Proc(JSON::Any, String)? = nil,
                   @dev : Bool = false, on_error = nil, @ready_timeout : Time::Span? = 60.seconds)
      @principal = Chord.json_value(principal)
      @principal_key = principal_key || Host.canonical_key
      @self_key = @principal_key.call(@principal)
      @on_error = Host.reporter(on_error)
    end

    def previous_code_version : Int32?
      nil
    end

    def serve(contract : Contract, *, lifetime : Lifetime = Lifetime::Referenced, linger : Time::Span? = nil,
              accepts : Accepts? = nil, &factory : JSON::Any, JSON::Any, ObjectScope -> Implementation) : Nil
      service = Service.new(contract, factory, lifetime, linger, accepts, "")
      serve_into(service)
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

    def get(type : Contract, input = nil, principal = nil, signal : AbortSignal? = nil) : Ref
      ref = acquire(type, input, principal.nil? ? nil : Chord.json_value(principal), RefOwner::External)
      Chord.await_ready(ref, signal ? [signal] : [] of AbortSignal, @ready_timeout)
      ref
    end

    def hold(type : Contract, input = nil, principal = nil) : Ref
      acquire(type, input, principal.nil? ? nil : Chord.json_value(principal), RefOwner::External)
    end

    def root(principal = nil, signal : AbortSignal? = nil, &)
      @root_seq += 1
      ctx = Ctx.new(self, signal ? [signal] : [] of AbortSignal, "#{@name}##{@incarnation}:#{@root_seq}", @code_version,
        principal.nil? ? @principal : Chord.json_value(principal))
      begin
        yield ctx
      ensure
        ctx.close
      end
    end

    def registry(registry : Registry(V)) : RegistryView(V) forall V
      RegistryView(V).new(self, registry)
    end

    def invalidate_principal(&match : JSON::Any -> Bool) : Nil
      invalidate(match)
    end

    def invalidate_principal(pattern) : Nil
      fields = Chord.json_value(pattern)
      invalidate(Host.pattern_matcher(fields))
    end

    def close : Nil
      @host_objects.clear
      @facet_runs.keys.each { |name| facet_run_changed(name, nil) }
      Host.dispose_holders_first(@objects.values, ChordError.new(ErrorCode::Gone, "host #{@name} closed"),
        "host close: disposal failed")
    end

    def report(error : Exception) : Nil
      @on_error.call(error)
    end

    protected def code_version?(code_version : Int32) : Bool
      code_version == @code_version
    end

    protected def service(type_name : String) : Service?
      @services[type_name]?
    end

    protected def serve_into(service : Service) : Nil
      contract = service.contract
      raise ArgumentError.new("#{contract.name} is already served") if @services.has_key?(contract.name)
      placement = contract.description.host
      if placement && !placement.placed_on?(@name)
        raise ArgumentError.new("#{contract.name} is declared for #{placement.text}, but #{@name} serves it")
      end
      @services[contract.name] = service
    end

    protected def acquire(type : Contract, input, principal : JSON::Any?, owner : RefOwner, from : ObjectImpl? = nil) : Ref
      raw = Chord.json_input(input)
      check_here(type, raw)
      service = @services[type.name]? || raise unknown_type(type.name)
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
      object ||= create_object(service, type, address, normalized, chosen)
      ref = Ref.new(object, type, owner)
      object.add_ref(ref)
      ref
    end

    protected def address_of(type : Contract, input, principal : JSON::Any) : String
      raw = Chord.json_input(input)
      check_here(type, raw)
      service = @services[type.name]? || raise unknown_type(type.name)
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
      if ctx && !code_version?(ctx.code_version)
        raise ChordError.new(ErrorCode::Superseded, "code version #{ctx.code_version} is retired")
      end
      @tables[registry.name]? || EMPTY_TABLE
    end

    protected def subscribe_registry(name : String, listener : TableListener) : Proc(Nil)
      listeners = @subscribers[name] ||= Listeners(TableListener).new
      id = listeners.add(listener)
      listener.call(@tables[name]? || EMPTY_TABLE, @code_version)
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
      install_tables(build_tables(entries))
    end

    private def install_facet(facet : Facet) : Array(Ref)
      raise ArgumentError.new("facet #{facet.name} is already installed") if @facets.has_key?(facet.name)
      added = [] of Service
      run = AbortController.new
      begin
        facet.setup.call(FacetApi.new(self, facet.name, run.signal, added))
      rescue error
        run.abort(error)
        raise error
      end
      @facets[facet.name] = facet
      facet_run_changed(facet.name, run)
      added.select(&.host_lifetime?).map { |service| start_host_object(service) }
    end

    private def facet_run_changed(name : String, run : AbortController?) : Nil
      replaced = @facet_runs[name]?
      run ? (@facet_runs[name] = run) : @facet_runs.delete(name)
      replaced.abort(ChordError.new(ErrorCode::Gone, "facet #{name} was replaced or removed")) if replaced && !replaced.same?(run)
    end

    private def start_host_object(service : Service) : Ref
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

    private def check_here(type : Contract, input : JSON::Any?) : Nil
      placement = type.description.host
      return unless type.remote? && placement
      normalized = Schema.normalize(type.input, input, "#{type.name} input")
      at = placement.resolve(type.name, normalized)
      raise ChordError.new(ErrorCode::Unavailable, "no route to #{at}") unless at == @name
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

    private def own_principal?(principal : JSON::Any) : Bool
      principal == @principal || @principal_key.call(principal) == @self_key
    end

    private def principal_part(principal : JSON::Any) : String
      own_principal?(principal) ? "host" : "p:#{@principal_key.call(principal)}"
    end

    private def unknown_type(type_name : String) : ChordError
      ChordError.new(ErrorCode::Unavailable, "#{type_name} is not served by #{@name}", reason: "unknown_type")
    end

    private def live_decls : Array(Tuple(ObjectImpl, Decls))
      @objects.values.select(&.status.live?).map { |object| {object, object.decls} }
    end

    private def build_tables(entries : Array(Tuple(ObjectImpl, Decls))) : Hash(String, RegistryTable)
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

    private def install_tables(tables : Hash(String, RegistryTable)) : Nil
      before = @tables
      @tables = tables
      @subscribers.each do |name, listeners|
        following = tables[name]? || EMPTY_TABLE
        next if Host.same_table?(before[name]? || EMPTY_TABLE, following)
        current = listeners.snapshot
        code_version = @code_version
        Publish.enqueue { notify_table(current, following, code_version) }
      end
    end

    private def notify_table(listeners, table : RegistryTable, code_version : Int32) : Nil
      listeners.each do |(_, listener)|
        listener.call(table, code_version)
      rescue error
        report(error)
      end
    end

    private def invalidate(matches : Proc(JSON::Any, Bool)) : Nil
      reason = ChordError.new(ErrorCode::Gone, "principal invalidated")
      matching = @objects.values.select { |object| !own_principal?(object.principal) && matches.call(object.principal) }
      Host.dispose_holders_first(matching, reason, "invalidatePrincipal: disposal failed")
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
        object.all_decls.each { |decls| decls.refs.each_value { |ref| stack << ref.object } }
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
      object.all_decls.each { |decls| decls.refs.each_value { |ref| result << ref.object } }
      result
    end
  end

  def self.create_host(**options) : Host
    Host.new(**options)
  end
end
