# src/llm/chord/future.cr
module LLM::Chord
  class Future(T)
    enum Outcome
      Settled
      Aborted
      TimedOut
    end

    @value : T? = nil
    @error : Exception? = nil
    @settled = false
    @done = Channel(Nil).new
    @callbacks = [] of Proc(Nil)

    def self.resolved(value : T) : Future(T)
      future = new
      future.resolve(value)
      future
    end

    def self.run(&block : -> T) : Future(T)
      future = new
      future.start(block)
      future
    end

    def settled? : Bool
      @settled
    end

    def rejected? : Bool
      @settled && !@error.nil?
    end

    def error : Exception?
      @error
    end

    def resolve(value : T) : Nil
      return if @settled
      @value = value
      settle
    end

    def reject(error : Exception) : Nil
      return if @settled
      @error = error
      settle
    end

    def on_settle(&callback : -> Nil) : Nil
      if @settled
        callback.call
      else
        @callbacks << callback
      end
    end

    def wait : T
      @done.receive? unless @settled
      result
    end

    def await_settled : Nil
      @done.receive? unless @settled
    end

    def wait(signals : Enumerable(AbortSignal), timeout : Time::Span?) : Outcome
      return Outcome::Settled if @settled
      return Outcome::Aborted if signals.any?(&.aborted?)
      aborted = Channel(Nil).new(1)
      removers = signals.map { |signal| signal.on_abort { |_reason| notify(aborted) } }
      begin
        span = timeout
        if span
          select
          when @done.receive?
            Outcome::Settled
          when aborted.receive
            Outcome::Aborted
          when timeout(span)
            Outcome::TimedOut
          end
        else
          select
          when @done.receive?
            Outcome::Settled
          when aborted.receive
            Outcome::Aborted
          end
        end
      ensure
        removers.each(&.call)
      end
    end

    protected def start(block : Proc(T)) : Nil
      spawn do
        begin
          resolve(block.call)
        rescue error
          reject(error)
        end
      end
    end

    private def notify(channel : Channel(Nil)) : Nil
      select
      when channel.send(nil)
      else
      end
    end

    private def settle : Nil
      @settled = true
      @done.close
      callbacks = @callbacks
      @callbacks = [] of Proc(Nil)
      callbacks.each(&.call)
    end

    private def result : T
      if error = @error
        raise error
      end
      @value.as(T)
    end
  end

  def self.race(future : Future(T), signal : AbortSignal) : T forall T
    if future.wait([signal], nil).aborted?
      raise ChordError.new(ErrorCode::Aborted, "call aborted", cause: signal.reason)
    end
    future.wait
  end

  def self.await_all(futures : Enumerable(Future)) : Nil
    futures.each(&.await_settled)
    futures.each { |future| future.error.try { |error| raise error } }
  end
end
