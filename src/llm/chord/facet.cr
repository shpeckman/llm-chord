# src/llm/chord/facet.cr
module LLM::Chord
  class Facet
    getter name : String
    getter uses : Array(Contract)
    getter setup : Proc(FacetApi, Nil)

    def initialize(@name : String, uses = nil, &setup : FacetApi ->)
      @uses = [] of Contract
      uses.try &.each { |contract| @uses << contract.as(Contract) }
      @setup = setup
    end
  end

  def self.define_facet(name : String, uses = nil, &setup : FacetApi ->) : Facet
    Facet.new(name, uses, &setup)
  end

  class FacetApi
    getter signal : AbortSignal

    def initialize(@host : Host, @facet : String, @signal : AbortSignal, @serve : Proc(Service, Nil)); end

    def name : String
      @host.name
    end

    def serve(contract : Contract, *, lifetime : Lifetime = Lifetime::Referenced, linger : Time::Span? = nil,
              accepts : Accepts? = nil, &factory : JSON::Any, JSON::Any, ObjectScope -> Implementation) : Nil
      @serve.call(Service.new(contract, factory, lifetime, linger, accepts, @facet))
    end

    def root(principal = nil, signal : AbortSignal? = nil, &)
      @host.root(principal, signal) { |ctx| yield ctx }
    end

    def registry(registry : Registry(V)) : RegistryView(V) forall V
      @host.registry(registry)
    end
  end
end
