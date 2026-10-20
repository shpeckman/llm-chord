# src/llm/chord/output.cr
module LLM::Chord::Output
  NEWLINE                   = 0x0a_u8
  PROGRESS_BYTES_PER_SECOND = 100 * 1024

  enum Retain
    Head
    Tail
  end

  record Limits, max_bytes : Int64, max_lines : Int64, retain : Retain do
    def self.head(max_lines : Int, max_bytes : Int) : Limits
      new(max_bytes.to_i64, max_lines.to_i64, Retain::Head)
    end

    def self.tail(max_lines : Int, max_bytes : Int) : Limits
      new(max_bytes.to_i64, max_lines.to_i64, Retain::Tail)
    end
  end

  record Bounded, text : String, dropped_bytes : Int64, dropped_lines : Int64
  record Excerpt, text : String, bytes : Int64, dropped_bytes : Int64, dropped_lines : Int64
  record Skip, bytes : Int64, newlines : Int64, ends_with_newline : Bool do
    def self.of(text : String) : Skip
      new(text.bytesize.to_i64, text.count('\n').to_i64, text.ends_with?('\n'))
    end
  end

  def self.sanitize(text : String) : String
    return text unless text.each_char.any? { |char| removed?(char) }
    String.build(text.bytesize) do |io|
      text.each_char { |char| io << char unless removed?(char) }
    end
  end

  def self.bound(text : String, limits : Limits) : Excerpt
    bytes = text.to_slice
    from, to = limits.retain.head? ? head_range(bytes, limits) : tail_range(bytes, limits)
    kept = bytes[from, to - from]
    Excerpt.new(
      kept.size == bytes.size ? text : String.new(kept),
      kept.size.to_i64,
      (bytes.size - kept.size).to_i64,
      line_count(bytes) - line_count(kept))
  end

  def self.character_end(bytes : Bytes, index : Int) : Int32
    position = index.to_i32
    while position > 0 && ((bytes[position]? || 0_u8) & 0xc0) == 0x80
      position -= 1
    end
    position
  end

  def self.utf8_byte_length(content : String) : Int64
    content.bytesize.to_i64
  end

  protected def self.character_start(bytes : Bytes, index : Int) : Int32
    position = index.to_i32
    while position < bytes.size && (bytes[position] & 0xc0) == 0x80
      position += 1
    end
    position
  end

  protected def self.lines(newlines : Int64, terminated : Bool) : Int64
    newlines + (terminated ? 0 : 1)
  end

  protected def self.tail_margin(text : String, limits : Limits) : String
    bytes = text.to_slice
    byte_start = bytes.size > limits.max_bytes ? character_end(bytes, bytes.size - limits.max_bytes - 1) : 0
    line_start = 0
    newlines = 0
    index = bytes.rindex(NEWLINE)
    while index
      newlines += 1
      if newlines > limits.max_lines
        line_start = index
        break
      end
      break if index == 0
      index = bytes.rindex(NEWLINE, index - 1)
    end
    start = Math.max(byte_start, line_start)
    start == 0 ? text : String.new(bytes[start..])
  end

  private def self.removed?(char : Char) : Bool
    code = char.ord
    code <= 0x08 || (0x0b <= code <= 0x1f) || (0xfff9 <= code <= 0xfffb)
  end

  private def self.head_range(bytes : Bytes, limits : Limits) : Tuple(Int32, Int32)
    return {0, 0} if limits.max_lines == 0 || limits.max_bytes == 0
    finish = bytes.size
    lines = 0
    index = bytes.index(NEWLINE)
    while index
      lines += 1
      if lines == limits.max_lines
        finish = index + 1
        break
      end
      index = bytes.index(NEWLINE, index + 1)
    end
    if finish > limits.max_bytes
      newline = bytes.rindex(NEWLINE, (limits.max_bytes - 1).to_i32)
      finish = newline ? newline + 1 : character_end(bytes, limits.max_bytes)
    end
    {0, finish}
  end

  private def self.tail_range(bytes : Bytes, limits : Limits) : Tuple(Int32, Int32)
    return {bytes.size, bytes.size} if limits.max_lines == 0 || limits.max_bytes == 0
    last = bytes.size > 0 && bytes[-1] == NEWLINE ? bytes.size - 2 : bytes.size - 1
    start = 0
    lines = 1
    index = last < 0 ? nil : bytes.rindex(NEWLINE, last)
    while index
      if lines == limits.max_lines
        start = index + 1
        break
      end
      lines += 1
      index = index == 0 ? nil : bytes.rindex(NEWLINE, index - 1)
    end
    if bytes.size - start > limits.max_bytes
      from = (bytes.size - limits.max_bytes).to_i32
      newline = bytes.index(NEWLINE, Math.max(from - 1, 0))
      start = newline && newline + 1 < bytes.size ? newline + 1 : character_start(bytes, from)
    end
    {start, bytes.size}
  end

  private def self.line_count(bytes : Bytes) : Int64
    return 0_i64 if bytes.empty?
    bytes.count(NEWLINE).to_i64 + (bytes[-1] == NEWLINE ? 0 : 1)
  end

  class Utf8StreamDecoder
    REPLACEMENT = '�'

    @needed = 0
    @seen = 0
    @code_point = 0
    @lower = 0x80
    @upper = 0xbf

    def decode(bytes : Bytes = Bytes.empty, stream : Bool = false) : String
      if @needed == 0 && !bytes.empty? && (whole = String.new(bytes)).valid_encoding?
        return whole
      end
      String.build(bytes.size) do |io|
        index = 0
        while index < bytes.size
          index += 1 if step(bytes[index], io)
        end
        if !stream && @needed != 0
          reset
          io << REPLACEMENT
        end
      end
    end

    private def step(byte : UInt8, io : IO) : Bool
      if @needed == 0
        case byte
        when 0x00..0x7f
          io << byte.unsafe_chr
        when 0xc2..0xdf
          @needed = 1
          @code_point = byte.to_i & 0x1f
        when 0xe0..0xef
          @lower = 0xa0 if byte == 0xe0
          @upper = 0x9f if byte == 0xed
          @needed = 2
          @code_point = byte.to_i & 0x0f
        when 0xf0..0xf4
          @lower = 0x90 if byte == 0xf0
          @upper = 0x8f if byte == 0xf4
          @needed = 3
          @code_point = byte.to_i & 0x07
        else
          io << REPLACEMENT
        end
        return true
      end
      unless @lower <= byte <= @upper
        reset
        io << REPLACEMENT
        return false
      end
      @lower = 0x80
      @upper = 0xbf
      @code_point = (@code_point << 6) | (byte.to_i & 0x3f)
      @seen += 1
      if @seen == @needed
        io << @code_point.unsafe_chr
        reset
      end
      true
    end

    private def reset : Nil
      @needed = 0
      @seen = 0
      @code_point = 0
      @lower = 0x80
      @upper = 0xbf
    end
  end

  class Buffer
    record Chunk, text : String, bytes : Int64, newlines : Int64

    getter stored_bytes : Int64 = 0_i64
    @decoder = Utf8StreamDecoder.new
    @started = false
    @chunks = Deque(Chunk).new
    @stored_newlines = 0_i64
    @full = false
    @total_bytes = 0_i64
    @total_newlines = 0_i64
    @ends_with_newline = true

    def initialize(@limits : Limits); end

    def push(chunk : String | Bytes, skipped : Skip? = nil) : Bool
      pending = chunk.is_a?(String) || skipped ? @decoder.decode : ""
      text = chunk.is_a?(String) ? chunk : @decoder.decode(chunk, stream: true)
      first = !@started && pending.empty? && skipped.nil?
      @started = true if !pending.empty? || !text.empty? || skipped
      text = text[1..] if first && chunk.is_a?(Bytes) && text.starts_with?('﻿')
      return accept(pending + text) unless skipped
      raise ArgumentError.new("Skipped output requires tail retention") unless @limits.retain.tail?
      accept(pending)
      skip(skipped)
      accept(text)
      true
    end

    def end : Nil
      accept(@decoder.decode)
    end

    def snapshot : Bounded
      stored = @chunks.size == 1 ? @chunks[0].text : @chunks.join(&.text)
      kept = Output.bound(stored, @limits)
      stored_lines = Output.lines(@stored_newlines, stored.empty? || stored.ends_with?('\n'))
      kept_lines = stored_lines - kept.dropped_lines
      if @limits.retain.tail? || @chunks.size > 1
        text = @limits.retain.tail? ? Output.tail_margin(stored, @limits) : stored
        bytes = @limits.retain.tail? ? text.bytesize.to_i64 : @stored_bytes
        @chunks.clear
        @chunks << Chunk.new(text, bytes, text.count('\n').to_i64) unless text.empty?
        @stored_bytes = bytes
        @stored_newlines = @chunks.first?.try(&.newlines) || 0_i64
      end
      Bounded.new(
        Output.sanitize(kept.text),
        @total_bytes - kept.bytes,
        Output.lines(@total_newlines, @ends_with_newline) - kept_lines)
    end

    private def skip(skipped : Skip) : Nil
      return if skipped.bytes == 0
      @total_bytes += skipped.bytes
      @total_newlines += skipped.newlines
      @ends_with_newline = skipped.ends_with_newline
      @chunks.clear
      @stored_bytes = 0_i64
      @stored_newlines = 0_i64
    end

    private def accept(text : String) : Bool
      return false if text.empty?
      bytes = text.bytesize.to_i64
      newlines = text.count('\n').to_i64
      @total_bytes += bytes
      @total_newlines += newlines
      @ends_with_newline = text.ends_with?('\n')
      return true if @full
      @chunks << Chunk.new(text, bytes, newlines)
      @stored_bytes += bytes
      @stored_newlines += newlines
      if @limits.retain.head?
        @full = @stored_bytes > @limits.max_bytes || @stored_newlines >= @limits.max_lines
        return true
      end
      while @chunks.size > 1
        first = @chunks[0]
        bytes_after = @stored_bytes - first.bytes
        newlines_after = @stored_newlines - first.newlines
        break if bytes_after <= @limits.max_bytes + 1 && newlines_after <= @limits.max_lines + 1
        @chunks.shift
        @stored_bytes = bytes_after
        @stored_newlines = newlines_after
      end
      true
    end
  end

  abstract class Clock
    abstract def now : Float64
    abstract def after(delay_ms : Float64, &callback : ->) : Proc(Nil)
  end

  class SystemClock < Clock
    @origin = Time.instant

    def now : Float64
      (Time.instant - @origin).total_milliseconds
    end

    class Timer
      getter? disarmed = false

      def disarm : Nil
        @disarmed = true
      end
    end

    def after(delay_ms : Float64, &callback : ->) : Proc(Nil)
      timer = Timer.new
      arm(timer, delay_ms, callback)
      disarmer(timer)
    end

    private def arm(timer : Timer, delay_ms : Float64, callback : ->) : Nil
      spawn do
        sleep delay_ms.milliseconds
        callback.call unless timer.disarmed?
      end
    end

    private def disarmer(timer : Timer) : Proc(Nil)
      -> { timer.disarm }
    end
  end

  SYSTEM_CLOCK = SystemClock.new

  class Waiter
    @done = Channel(Nil).new
    @error : Exception? = nil
    getter? settled = false

    def resolve : Nil
      settle(nil)
    end

    def reject(error : Exception) : Nil
      settle(error)
    end

    def wait : Nil
      @done.receive?
      if error = @error
        raise error
      end
    end

    private def settle(error : Exception?) : Nil
      return if @settled
      @settled = true
      @error = error
      @done.close
    end
  end

  class Progress
    @waiters = [] of Waiter
    @timer : Proc(Nil)? = nil
    @in_flight : Channel(Nil)? = nil
    @next_at = 0.0
    @dirty = false
    @stopped = false
    @min_interval_ms : Float64

    def initialize(@write : -> Int64, @on_error : Exception -> Nil, min_interval_ms : Number, @clock : Clock = SYSTEM_CLOCK)
      @min_interval_ms = min_interval_ms.to_f64
    end

    def mark : Nil
      @dirty = true
      schedule
    end

    def mark_and_wait : Waiter
      waiter = Waiter.new
      @waiters << waiter
      mark
      waiter
    end

    def stop : Array(Waiter)
      @stopped = true
      @timer.try(&.call)
      @timer = nil
      @in_flight.try(&.receive?)
      waiters = @waiters.dup
      @waiters.clear
      waiters
    end

    private def schedule : Nil
      return if @stopped || @timer || @in_flight
      wait = @next_at - @clock.now
      if wait <= 0
        flush
      else
        @timer = @clock.after(wait) do
          @timer = nil
          schedule
        end
      end
    end

    private def flush : Nil
      return if @stopped || !@dirty
      @dirty = false
      waiters = @waiters.dup
      @waiters.clear
      started = @clock.now
      done = Channel(Nil).new
      @in_flight = done
      spawn do
        bytes = @write.call
        @next_at = started + Math.max(@min_interval_ms, bytes * 1000.0 / PROGRESS_BYTES_PER_SECOND)
        waiters.each(&.resolve)
      rescue error
        @next_at = started + @min_interval_ms
        waiters.each(&.reject(error))
        report(error)
      ensure
        @in_flight = nil
        done.close
        schedule if @dirty
      end
    end

    private def report(error : Exception) : Nil
      @on_error.call(error)
    rescue ex
      REPORT_ASYNC.call(ex)
    end
  end
end
