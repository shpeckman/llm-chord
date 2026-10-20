# spec/spec_helper.cr
require "spec"
require "../src/llm-chord"

include LLM::Chord
include LLM::Chord::Delta

def j(text : String) : JSON::Any
  JSON.parse(text)
end

def list(*items : JSON::Any) : JSON::Any
  JSON::Any.new(items.to_a)
end

def list(items : Array(JSON::Any)) : JSON::Any
  JSON::Any.new(items)
end

def doc(**fields) : JSON::Any
  hash = {} of String => JSON::Any
  fields.each { |key, value| hash[key.to_s] = value.is_a?(JSON::Any) ? value : Json.to_any(value) }
  JSON::Any.new(hash)
end

def path(*segs : String | Int32) : Delta::Path
  result = Delta::Path.new
  segs.each { |seg| result << seg }
  result
end

def tuples(ops : Array(Op)) : JSON::Any
  JSON::Any.new(ops.map(&.to_tuple))
end

def expect_diff(before : JSON::Any, after : JSON::Any, expected : String) : Array(Op)
  ops = Delta.diff_revisions(before, after)
  tuples(ops).should eq j(expected)
  Json.equal?(Delta.apply_immutable(before, ops), after).should be_true
  ops
end

def same?(left : JSON::Any, right : JSON::Any) : Bool
  Json.identical?(left, right)
end

def ops(text : String) : Array(Op)
  j(text).as_a.map { |tuple| Op.from_tuple(tuple) }
end

def tick : Nil
  sleep 1.millisecond
end

def eventually(timeout : Time::Span = 2.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "condition not reached" if Time.instant > deadline
    sleep 1.millisecond
  end
end

def wait_abort(signal : AbortSignal) : Nil
  return if signal.aborted?
  done = Channel(Nil).new(1)
  signal.on_abort { done.send(nil) }
  done.receive
end

def notify(channel : Channel(Nil)) : Nil
  select
  when channel.send(nil)
  else
  end
end

def event_json(event : StateEvent) : JSON::Any
  kind = JSON::Any.new(event.kind.to_s.downcase)
  JSON::Any.new([kind, event.kind.ops? ? tuples(event.ops) : event.value])
end

def quiet_host(errors : Array(Exception) = [] of Exception) : Host
  LLM::Chord.create_host(self: {kind: "host"}, on_error: ->(error : Exception) { errors << error })
end

def wire(t : String, **fields) : Frame
  Frame.build(t, **fields)
end

def state_frames(frames : Array(Frame)) : Array(Frame)
  frames.select { |frame| frame.t == "state" }
end

def quiet_on_error : Proc(Exception, Nil)
  ->(_error : Exception) { }
end

class CountingLink < LLM::Chord::Link
  getter inner : LLM::Chord::Link
  getter sent = [] of Frame
  getter received = [] of Frame
  property? paused = false
  @held : Frame? = nil

  def initialize(@inner : LLM::Chord::Link); end

  def closed? : Bool
    @inner.closed?
  end

  def send(frame : Frame) : Int32?
    if frame.t == "ack" && @paused
      @held = frame
      return 0
    end
    @sent << frame
    @inner.send(frame)
  end

  def release : Nil
    @paused = false
    held = @held
    @held = nil
    @inner.send(held) if held
  end

  def receive(&handler : Frame -> Nil) : Nil
    hook(handler)
  end

  def on_close(&handler : String -> Nil) : Nil
    @inner.on_close(&handler)
  end

  def close(reason : String = "closed") : Nil
    @inner.close(reason)
  end

  def count(direction : Symbol, t : String) : Int32
    (direction == :sent ? @sent : @received).count { |frame| frame.t == t }
  end

  def traffic(direction : Symbol) : Array(Frame)
    (direction == :sent ? @sent : @received).reject { |frame| {"ping", "pong", "ack"}.includes?(frame.t) }
  end

  private def hook(handler : Proc(Frame, Nil)) : Nil
    @inner.receive do |frame|
      @received << frame
      handler.call(frame)
    end
  end
end

class Emitter
  include Subscribable

  @listeners = {} of Int32 => Proc(JSON::Any, Nil)
  @next = 0

  def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
    add(listener)
  end

  def emit(value) : Nil
    @listeners.values.each(&.call(Json.to_any(value)))
  end

  def size : Int32
    @listeners.size
  end

  private def add(listener : Proc(JSON::Any, Nil)) : Proc(Nil)
    id = @next += 1
    @listeners[id] = listener
    -> { @listeners.delete(id); nil }
  end
end
