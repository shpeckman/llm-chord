# src/llm/chord/context.cr
class LLM::Chord::Context
  def initialize
    @entries = {} of String => JSON::Any
  end

  def provide(name : String, value : JSON::Any) : Nil
    raise ArgumentError.new("context entry already provided: #{name}") if @entries.has_key?(name)
    @entries[name] = value
  end

  def require(name : String) : JSON::Any
    @entries[name]? || raise ArgumentError.new("context entry is missing: #{name}")
  end

  def fetch(name : String) : JSON::Any?
    @entries[name]?
  end
end
