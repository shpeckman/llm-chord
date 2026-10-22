# src/llm-chord/link.cr
require "socket"

module LLM::Chord
  abstract class Link
    abstract def closed? : Bool
    abstract def send(frame : Frame) : Int32?
    abstract def receive(&handler : Frame -> Nil) : Nil
    abstract def on_close(&handler : String -> Nil) : Nil
    abstract def close(reason : String = "closed") : Nil
  end

  abstract class BaseLink < Link
    @handler : Proc(Frame, Nil)? = nil
    @queue = [] of Frame
    @close_handlers = [] of Proc(String, Nil)
    @closed = false

    def closed? : Bool
      @closed
    end

    protected abstract def transmit(frame : Frame) : Int32?
    protected abstract def shutdown : Nil

    def send(frame : Frame) : Int32?
      return if @closed
      transmit(frame)
    end

    def receive(&handler : Frame -> Nil) : Nil
      install_handler(handler)
    end

    def on_close(&handler : String -> Nil) : Nil
      if @closed
        handler.call("closed")
      else
        @close_handlers << handler
      end
    end

    def close(reason : String = "closed") : Nil
      return if @closed
      begin
        transmit(Frame.build("bye", reason: reason))
      rescue
      end
      ended(reason)
    end

    protected def deliver(frame : Frame) : Nil
      return if @closed
      if frame.t == "bye"
        ended(frame.string?("reason") || "peer closed")
        return
      end
      if handler = @handler
        handler.call(frame)
      else
        @queue << frame
      end
    end

    protected def ended(reason : String) : Nil
      return if @closed
      @closed = true
      @queue.clear
      begin
        shutdown
      ensure
        handlers = @close_handlers.dup
        @close_handlers.clear
        handlers.each(&.call(reason))
      end
    end

    private def install_handler(handler : Proc(Frame, Nil)) : Nil
      @handler = handler
      queued = @queue.dup
      @queue.clear
      queued.each { |frame| handler.call(frame) }
    end
  end

  class MemoryLink < BaseLink
    property peer : MemoryLink? = nil
    @severed = false
    @tasks = Deque(Proc(Nil)).new
    @pumping = false

    def sever : Nil
      @severed = true
      @peer.try &.sever_from_peer
    end

    protected def sever_from_peer : Nil
      @severed = true
    end

    protected def transmit(frame : Frame) : Int32?
      return if @severed
      data = Wire.encode_object(frame, true)
      peer = @peer
      schedule(-> { arrive(peer, data) })
      data.bytesize
    end

    protected def shutdown : Nil
      peer = @peer
      schedule(-> { peer.try &.ended("peer closed"); nil })
    end

    private def arrive(peer : MemoryLink?, data : String) : Nil
      return if @severed || peer.nil?
      frame = begin
        Wire.parse(data)
      rescue
        peer.close("protocol error")
        return
      end
      peer.deliver(frame)
    end

    private def schedule(task : Proc(Nil)) : Nil
      @tasks << task
      return if @pumping
      @pumping = true
      spawn { pump }
    end

    private def pump : Nil
      while task = @tasks.shift?
        task.call
      end
    ensure
      @pumping = false
    end
  end

  def self.memory_link_pair : Tuple(MemoryLink, MemoryLink)
    a = MemoryLink.new
    b = MemoryLink.new
    a.peer = b
    b.peer = a
    {a, b}
  end

  class IpcChannel
    @messages = Listeners(Proc(JSON::Any, Nil)).new
    @disconnects = Listeners(Proc(Nil)).new
    @lock = Mutex.new
    @connected = true
    @started = false

    def initialize(@io : IO); end

    def self.from_env : IpcChannel?
      fd = ENV["NODE_CHANNEL_FD"]?.try(&.to_i?)
      return unless fd
      channel = new(UNIXSocket.new(fd: fd))
      channel.start
      channel
    end

    def connected? : Bool
      @connected
    end

    def send(message : JSON::Any) : Exception?
      send_line(message.to_json)
    end

    def send_line(line : String) : Exception?
      return IO::Error.new("ipc channel disconnected") unless @connected
      @lock.synchronize do
        @io << line << '\n'
        @io.flush
      end
      nil
    rescue error : IO::Error
      error
    end

    def on_message(&listener : JSON::Any -> Nil) : Proc(Nil)
      @messages.remover(@messages.add(listener))
    end

    def on_disconnect(&listener : -> Nil) : Proc(Nil)
      @disconnects.remover(@disconnects.add(listener))
    end

    def start : Nil
      return if @started
      @started = true
      spawn { read_loop }
    end

    def close : Nil
      return unless @connected
      @io.close rescue nil
      disconnected
    end

    private def read_loop : Nil
      while line = @io.gets
        next if line.empty?
        message = JSON.parse(line) rescue next
        @messages.snapshot.each { |(_, listener)| listener.call(message) }
      end
    rescue IO::Error
    ensure
      disconnected
    end

    private def disconnected : Nil
      return unless @connected
      @connected = false
      @disconnects.snapshot.each { |(_, listener)| listener.call }
    end
  end

  class IpcLink < BaseLink
    @remove_message : Proc(Nil)? = nil
    @remove_disconnect : Proc(Nil)? = nil

    def initialize(@channel : IpcChannel)
      @remove_message = @channel.on_message { |message| on_message(message) }
      @remove_disconnect = @channel.on_disconnect { ended("ipc disconnected") }
      @channel.start
      ended("ipc disconnected") unless @channel.connected?
    end

    protected def transmit(frame : Frame) : Int32?
      return unless @channel.connected?
      if error = @channel.send_line(%({"chord2":#{Wire.encode_object(frame, true)}}))
        reason = "ipc send failed: #{error.as?(IO::Error).try(&.os_error).try(&.to_s) || error.message}"
        spawn { ended(reason) }
      end
      nil
    end

    protected def shutdown : Nil
      @remove_message.try &.call
      @remove_disconnect.try &.call
    end

    private def on_message(message : JSON::Any) : Nil
      frame = message.as_h?.try(&.["chord2"]?)
      return unless frame
      deliver(Wire.decode_object(frame))
    rescue
      close("protocol error")
    end
  end

  def self.ipc_link(channel : IpcChannel) : IpcLink
    IpcLink.new(channel)
  end
end
