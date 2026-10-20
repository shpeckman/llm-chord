# src/llm/chord/registry.cr
module LLM::Chord
  enum RegistryConflict
    Error
    Last
  end

  abstract class AnyRegistry
    getter name : String
    getter conflict : RegistryConflict

    def initialize(@name : String, @conflict : RegistryConflict = RegistryConflict::Error); end
  end

  class Registry(V) < AnyRegistry
  end

  abstract class RegistryEntry
  end

  class RegistryValue(V) < RegistryEntry
    getter value : V

    def initialize(@value : V); end
  end

  record Registration, registry : AnyRegistry, key : String, entry : RegistryEntry

  alias RegistryTable = Hash(String, RegistryEntry)
  alias TableListener = Proc(RegistryTable, Int32, Nil)

  struct RegistryView(V)
    def initialize(@host : Host, @registry : Registry(V)); end

    def table(ctx : Ctx? = nil) : Hash(String, V)
      RegistryView(V).typed(@host.registry_table(@registry, ctx))
    end

    def get(key : String, ctx : Ctx? = nil) : V?
      @host.registry_table(@registry, ctx)[key]?.try { |entry| entry.as(RegistryValue(V)).value }
    end

    def subscribe(&listener : Hash(String, V), Int32 -> Nil) : Proc(Nil)
      @host.subscribe_registry(@registry.name, RegistryView(V).erase(listener))
    end

    protected def self.typed(table : RegistryTable) : Hash(String, V)
      table.transform_values { |entry| entry.as(RegistryValue(V)).value }
    end

    protected def self.erase(listener : Proc(Hash(String, V), Int32, Nil)) : TableListener
      ->(table : RegistryTable, code_version : Int32) { listener.call(typed(table), code_version) }
    end
  end

  def self.define_registry(_type : V.class, name : String, conflict : RegistryConflict = RegistryConflict::Error) : Registry(V) forall V
    Registry(V).new(name, conflict)
  end
end
