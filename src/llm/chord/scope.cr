# src/llm/chord/scope.cr
module LLM::Chord
  class ObjectScope
    protected getter run = Run.new

    def initialize(@object : ObjectImpl, @previous : Decls? = nil); end

    def state(name : String, schema : TypeBox::Schema, initial, version : Int32 = 1,
              migrate : Proc(JSON::Any, Int32, JSON::Any)? = nil) : Cell
      declare_cell(name, schema, Chord.json_value(initial), nil, version, migrate)
    end

    def state(name : String, schema : TypeBox::Schema, version : Int32 = 1,
              migrate : Proc(JSON::Any, Int32, JSON::Any)? = nil, &init : Ctx -> T) : Cell forall T
      declare_cell(name, schema, nil, ObjectScope.init_fn(init), version, migrate)
    end

    def get(type : Contract, input = nil, principal = nil, state : Bool = true) : Ref
      host = @object.host
      chosen = principal.nil? ? host.principal : Chord.json_value(principal)
      address = host.address_of(type, input, chosen)
      if declared = @run.decls.refs[address]?
        unless declared.contract.fingerprint == type.fingerprint
          raise Chord.invalid("duplicate", "#{@object.type_name}: #{type.name} held twice with different contracts")
        end
        return declared
      end
      ref = host.acquire(type, input, chosen, RefOwner::Object, @object, state)
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

    private def declare_cell(name : String, schema : TypeBox::Schema, initial : JSON::Any?, init : InitFn?) : Cell
      unique(@run.decls.cells, "state", name)
      cell = Cell.new(name, schema, initial, @object.guard, @object.host.source_options)
      @run.inits << {cell, init} if init
      @run.decls.cells[name] = cell
      cell
    end

    private def declare_resource(name : String, version : Int32, deps, exclusive : Bool, opener : Proc(AbortSignal, T),
                                 closer : Proc(T, Nil)?) : Resource(T) forall T
      unique(@run.decls.resources, "resource", name)
      resolved = [] of ResourceDep
      deps.try &.each { |dep| resolved << dep.as(ResourceDep) }
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

    private def listen(name : String, origin : AnyResource | Subscribable, source : Proc(Subscribable), fn : ListenerFn) : Nil
      unique(@run.decls.listeners, "listener", name)
      @run.decls.listeners[name] = ListenerDecl.new(origin, source, fn)
    end

    private def listen_source(name : String, source : Subscribable, fn : ListenerFn) : Nil
      listen(name, source, -> { source.as(Subscribable) }, fn)
    end

    private def listen_resource(name : String, resource : AnyResource, fn : ListenerFn) : Nil
      listen(name, resource, -> { resource.subscribable }, fn)
    end

    private def listen_selected(name : String, resource : Resource(T), selector : Proc(T, U), fn : ListenerFn) : Nil forall T, U
      listen(name, resource, -> { selector.call(resource.open_value).as(Subscribable) }, fn)
    end

    protected def self.init_fn(init : Proc(Ctx, T)) : InitFn forall T
      ->(ctx : Ctx) { Chord.json_value(init.call(ctx)) }
    end

    protected def self.derive_fn(fn : Proc(Array(JSON::Any), T)) : Proc(Array(JSON::Any), JSON::Any) forall T
      ->(values : Array(JSON::Any)) { Chord.json_value(fn.call(values)) }
    end

    protected def self.closer(_close : Nil, _type : T.class) : Proc(T, Nil)? forall T
      nil
    end

    protected def self.closer(close : Proc(T, U), _type : T.class) : Proc(T, Nil)? forall T, U
      ->(value : T) { close.call(value); nil }
    end
  end
end
