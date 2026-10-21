# src/llm/chord/scope.cr
module LLM::Chord
  class ObjectScope
    protected getter run = Run.new

    def initialize(@object : ObjectImpl, @previous : Decls? = nil); end

    def state(name : String, schema : TypeBox::Schema, initial, *, version : Int32 = 1, migrate = nil) : Cell
      declare_cell(name, schema, version, ObjectScope.migration(migrate)) do
        Cell.new(name, schema, Chord.json_value(initial), @object.guard, @object.host.source_options)
      end
    end

    def state(name : String, schema : TypeBox::Schema, *, version : Int32 = 1, migrate = nil,
              &init : Ctx -> T) : Cell forall T
      declare_cell(name, schema, version, ObjectScope.migration(migrate)) do
        cell = Cell.new(name, schema, nil, @object.guard, @object.host.source_options)
        @run.inits << {cell, ObjectScope.init_fn(init)}
        cell
      end
    end

    def get(type : Contract, input = nil, principal = nil, state : Bool = true) : Ref
      host = @object.host
      candidate = !@previous.nil?
      chosen = principal.nil? ? host.principal : Chord.json_value(principal)
      address = host.address_of(type, input, chosen, candidate)
      if declared = @run.decls.refs[address]?
        unless declared.contract.fingerprint == type.fingerprint
          raise Chord.invalid("duplicate", "#{@object.type_name}: #{type.name} held twice with different contracts")
        end
        return declared
      end
      existing = @previous.try(&.refs[address]?)
      if existing && existing.contract.fingerprint == type.fingerprint && !existing.ended?
        @run.decls.refs[address] = existing
        return existing
      end
      ref = host.acquire(type, input, chosen, RefOwner::Object, @object, state, candidate)
      @run.decls.refs[address] = ref
      @run.created_refs << ref
      ref
    end

    def resource(name : String, *, version : Int32, deps = nil, exclusive : Bool = false, close = nil,
                 &open : AbortSignal -> T) : Resource(T) forall T
      declare_resource(name, version, deps, exclusive, open, ObjectScope.closer(close, T))
    end

    def on(name : String, source : Subscribable, &handler : JSON::Any, Ctx ->) : Nil
      listen_source(name, source, handler)
    end

    def on(name : String, source : Resource(T), &handler : JSON::Any, Ctx ->) : Nil forall T
      listen_resource(name, source, handler)
    end

    def on(name : String, source : Resource(T), selector : Proc(T, U), &handler : JSON::Any, Ctx ->) : Nil forall T, U
      listen_selected(name, source, selector, handler)
    end

    def task(&fn : Ctx ->) : Nil
      @run.decls.tasks["##{@run.decls.tasks.size}"] = fn
    end

    def derive(sources : Array, &fn : Array(JSON::Any) -> T) : Derived forall T
      declare_derived(sources.map(&.as(Readable)), ObjectScope.derive_fn(fn))
    end

    def register(registry : Registry(V), entries : Hash(String, V)) : Nil forall V
      unless @object.host_lifetime?
        raise Chord.invalid("not_host_lifetime", %(#{@object.type_name}: only objects of lifetime "host" may register))
      end
      entries.each do |key, value|
        id = "#{registry.name}\u0000#{key}"
        unique(@run.decls.registrations, "register", id)
        @run.decls.registrations[id] = Registration.new(registry, key, RegistryValue(V).new(value))
      end
    end

    def register(registry : Registry(V), entries : NamedTuple) : Nil forall V
      table = {} of String => V
      entries.each { |key, value| table[key.to_s] = value.as(V) }
      register(registry, table)
    end

    def expose(resource : Resource(T)) : Exposed forall T
      unless @run.decls.resources.values.any?(&.same?(resource))
        raise ArgumentError.new("expose takes a resource declared by this object")
      end
      Exposed.new(resource)
    end

    private def unique(map : Hash, kind : String, name : String) : Nil
      raise ArgumentError.new("#{kind} needs a name") if name.empty?
      raise Chord.invalid("duplicate", "#{@object.type_name}: duplicate #{kind} name #{name}") if map.has_key?(name)
    end

    private def declare_cell(name : String, schema : TypeBox::Schema, version : Int32, migration : Migration?, & : -> Cell) : Cell
      unique(@run.decls.cells, "state", name)
      raise ArgumentError.new("state #{name}: version must be a positive integer") if version < 1
      cell = @previous.try(&.cells[name]?) || yield
      decls = @run.decls
      decls.cells[name] = cell
      decls.cell_schemas[name] = schema
      decls.cell_versions[name] = version
      migration.try { |fn| decls.cell_migrations[name] = fn }
      cell
    end

    private def declare_resource(name : String, version : Int32, deps, exclusive : Bool, opener : Proc(AbortSignal, T),
                                 closer : Proc(T, Nil)?) : Resource(T) forall T
      unique(@run.decls.resources, "resource", name)
      resolved = [] of ResourceDep
      deps.try &.each { |dep| resolved << dep.as(ResourceDep) }
      existing = @previous.try(&.resources[name]?)
      if existing.is_a?(Resource(T)) && existing.version == version && existing.exclusive? == exclusive &&
         ObjectScope.same_deps?(existing.deps, resolved)
        @run.decls.adopted[existing] = ObjectScope.adopter(existing, opener, closer)
        @run.decls.resources[name] = existing
        return existing
      end
      resource = Resource(T).new(name, version, exclusive, resolved, @object.host, opener, closer)
      @run.created_resources << resource
      @run.decls.resources[name] = resource
      resource
    end

    private def declare_derived(sources : Array(Readable), fn : Proc(Array(JSON::Any), JSON::Any)) : Derived
      key = "##{@run.decls.derives.size}"
      derived = Derived.new(key, sources, fn, @object.host.source_options)
      @run.created_derives << derived
      @run.decls.derives[key] = derived
      derived
    end

    private def listen(name : String, origin : AnyResource | Subscribable, selector : UInt64?, source : Proc(Subscribable),
                       fn : ListenerFn) : Nil
      unique(@run.decls.listeners, "listener", name)
      @run.decls.listeners[name] = ListenerDecl.new(origin, selector, source, fn)
    end

    private def listen_source(name : String, source : Subscribable, fn : ListenerFn) : Nil
      listen(name, source, nil, -> { source.as(Subscribable) }, fn)
    end

    private def listen_resource(name : String, resource : AnyResource, fn : ListenerFn) : Nil
      listen(name, resource, nil, -> { resource.subscribable }, fn)
    end

    private def listen_selected(name : String, resource : Resource(T), selector : Proc(T, U), fn : ListenerFn) : Nil forall T, U
      listen(name, resource, selector.pointer.address, -> { selector.call(resource.open_value).as(Subscribable) }, fn)
    end

    protected def self.init_fn(init : Proc(Ctx, T)) : InitFn forall T
      ->(ctx : Ctx) { Chord.json_value(init.call(ctx)) }
    end

    protected def self.derive_fn(fn : Proc(Array(JSON::Any), T)) : Proc(Array(JSON::Any), JSON::Any) forall T
      ->(values : Array(JSON::Any)) { Chord.json_value(fn.call(values)) }
    end

    protected def self.migration(_migrate : Nil) : Migration?
      nil
    end

    protected def self.migration(migrate : Proc(JSON::Any, Int32, U)) : Migration? forall U
      ->(old : JSON::Any, from : Int32) { Chord.json_value(migrate.call(old, from)) }
    end

    protected def self.adopter(resource : Resource(T), opener : Proc(AbortSignal, T), closer : Proc(T, Nil)?) : Proc(Nil) forall T
      -> { resource.adopt(opener, closer) }
    end

    protected def self.same_deps?(left : Array(ResourceDep), right : Array(ResourceDep)) : Bool
      left.size == right.size && left.zip(right).all? { |(a, b)| a.same?(b) }
    end

    protected def self.closer(_close : Nil, _type : T.class) : Proc(T, Nil)? forall T
      nil
    end

    protected def self.closer(close : Proc(T, U), _type : T.class) : Proc(T, Nil)? forall T, U
      ->(value : T) { close.call(value); nil }
    end
  end
end
