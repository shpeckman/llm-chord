# src/llm/chord/cell.cr
module LLM::Chord
  class Cell
    @listeners = [] of Proc(JSON::Any, Nil)

    def self.from(state : ReplicatedState, &compute : JSON::Any -> JSON::Any) : Cell
      cell = new(compute.call(state.value))
      state.subscribe { |value, _delivery| cell.update(compute.call(value)) }
      cell
    end

    def initialize(@value : JSON::Any); end

    def value : JSON::Any
      @value
    end

    def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
      box = listener
      @listeners << box
      box.call(@value)
      -> { @listeners.delete(box) }
    end

    def update(value : JSON::Any) : Nil
      return if value == @value
      @value = value
      @listeners.each(&.call(value))
    end
  end
end
