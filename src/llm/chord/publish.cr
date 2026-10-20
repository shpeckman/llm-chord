# src/llm/chord/publish.cr
module LLM::Chord::Publish
  @@queue = Deque(Proc(Nil)).new
  @@held = 0
  @@draining = false

  def self.enqueue(&task : -> Nil) : Nil
    @@queue << task
    drain
  end

  def self.hold(&)
    @@held += 1
    begin
      yield
    ensure
      @@held -= 1
      drain
    end
  end

  private def self.drain : Nil
    return if @@draining || @@held > 0
    @@draining = true
    begin
      while task = @@queue.shift?
        task.call
      end
    ensure
      @@draining = false
    end
  end
end
