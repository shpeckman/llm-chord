# src/llm-chord/manager.cr
require "digest/sha256"
require "socket"

lib LibChordSpawn
  POSIX_SPAWN_SETPGROUP  = 0x02
  POSIX_SPAWN_SETSIGDEF  = 0x04
  POSIX_SPAWN_SETSIGMASK = 0x08
  F_DUPFD_CLOEXEC        = {% if flag?(:darwin) %} 67 {% else %} 1030 {% end %}

  fun posix_spawn_file_actions_init(actions : Void*) : LibC::Int
  fun posix_spawn_file_actions_destroy(actions : Void*) : LibC::Int
  fun posix_spawn_file_actions_adddup2(actions : Void*, fd : LibC::Int, newfd : LibC::Int) : LibC::Int
  fun posix_spawnattr_init(attr : Void*) : LibC::Int
  fun posix_spawnattr_destroy(attr : Void*) : LibC::Int
  fun posix_spawnattr_setflags(attr : Void*, flags : LibC::Short) : LibC::Int
  fun posix_spawnattr_setpgroup(attr : Void*, pgroup : LibC::PidT) : LibC::Int
  fun posix_spawnattr_setsigmask(attr : Void*, mask : LibC::SigsetT*) : LibC::Int
  fun posix_spawnattr_setsigdefault(attr : Void*, mask : LibC::SigsetT*) : LibC::Int
  fun posix_spawnp(pid : LibC::PidT*, file : LibC::Char*, actions : Void*, attr : Void*, argv : LibC::Char**, envp : LibC::Char**) : LibC::Int
end

module LLM::Chord
  LOCK_ENV   = "CHORD2_LOCK"
  CHANNEL_FD = 3

  struct ControlMessage
    include JSON::Serializable

    getter type : String
    getter value : JSON::Any?
    getter message : String?
    getter reason : String?
    @[JSON::Field(key: "activeCalls")]
    getter active_calls : Int32?
    getter viewers : Int32?
    @[JSON::Field(key: "durableTasks")]
    getter durable_tasks : Int32?

    def initialize(@type : String, @value : JSON::Any? = nil, @message : String? = nil, @reason : String? = nil,
                   @active_calls : Int32? = nil, @viewers : Int32? = nil, @durable_tasks : Int32? = nil); end

    def self.from(message : JSON::Any) : ControlMessage?
      control = message.as_h?.try(&.["chord2control"]?)
      return unless control
      from_json(control.to_json)
    rescue JSON::Error
      nil
    end

    def wire : String
      %({"chord2control":#{to_json}})
    end
  end

  record Exit, code : Int32?, signal : String?

  record Liveness, booting : Bool, active_calls : Int32, viewers : Int32, durable_tasks : Int32, idle_for : Time::Span

  abstract class Instance
    abstract def pid : Int64
    abstract def link : Link
    abstract def exited : Future(Exit)
    abstract def send(message : ControlMessage) : Nil
    abstract def kill_tree : Nil
    abstract def on_control(&listener : ControlMessage -> Nil) : Nil
  end

  abstract class Driver
    abstract def spawn : Instance
  end

  class ForkInstance < Instance
    getter pid : Int64
    getter link : Link
    getter exited : Future(Exit) = Future(Exit).new
    @listeners = Listeners(Proc(ControlMessage, Nil)).new

    def initialize(@pid : Int64, @channel : IpcChannel, on_message : Proc(JSON::Any, Nil)?)
      @link = IpcLink.new(@channel)
      @channel.on_message { |message| dispatch(message, on_message) }
    end

    def send(message : ControlMessage) : Nil
      @channel.send_line(message.wire) if @channel.connected?
    end

    def kill_tree : Nil
      ForkInstance.kill_group(@pid)
    end

    def on_control(&listener : ControlMessage -> Nil) : Nil
      @listeners.add(listener)
    end

    protected def self.kill_group(pid : Int64) : Nil
      LibC.kill(-pid.to_i32, Signal::KILL.value)
    end

    private def dispatch(message : JSON::Any, tap : Proc(JSON::Any, Nil)?) : Nil
      tap.try &.call(message)
      control = ControlMessage.from(message)
      @listeners.snapshot.each { |(_, listener)| listener.call(control) } if control
    end
  end

  class ForkDriver < Driver
    getter entry : String
    getter args : Array(String)
    getter env : Hash(String, String)
    getter init : JSON::Any?
    getter lock : String?

    def initialize(@entry : String, @args : Array(String) = [] of String, @env : Hash(String, String) = {} of String => String,
                   @init : JSON::Any? = nil, @lock : String? = nil,
                   @on_output : Proc(Symbol, Bytes, Nil)? = nil, @on_message : Proc(JSON::Any, Nil)? = nil)
    end

    def spawn : Instance
      parent, child = UNIXSocket.pair
      outputs = @on_output ? {IO.pipe, IO.pipe} : nil
      pid = begin
        ForkDriver.posix_spawn(@entry, @args, environment, child, outputs.try { |(out_pipe, err_pipe)| {out_pipe[1], err_pipe[1]} })
      ensure
        child.close
        outputs.try &.each { |pipe| pipe[1].close }
      end
      outputs.try { |(out_pipe, err_pipe)| tap_output(out_pipe[0], err_pipe[0]) }
      channel = IpcChannel.new(parent)
      instance = ForkInstance.new(pid, channel, @on_message)
      ::spawn { watch(pid, instance) }
      @init.try { |value| instance.send(ControlMessage.new("init", value: value)) }
      instance
    end

    private def environment : Hash(String, String)
      env = ENV.to_h
      env.delete(LOCK_ENV)
      env.merge!(@env)
      @lock.try { |name| env[LOCK_ENV] = name }
      env["NODE_CHANNEL_FD"] = CHANNEL_FD.to_s
      env["NODE_CHANNEL_SERIALIZATION_MODE"] = "json"
      env
    end

    private def watch(pid : Int64, instance : ForkInstance) : Nil
      status = Process.new(Crystal::System::Process.new(pid.to_i32)).wait
      ForkInstance.kill_group(pid)
      signal = status.exit_signal?
      instance.exited.resolve(Exit.new(signal ? nil : status.exit_code, signal.try { |found| "SIG#{found}" }))
    end

    private def tap_output(stdout : IO, stderr : IO) : Nil
      tap = @on_output.not_nil!
      ::spawn { pump(stdout, :stdout, STDOUT, tap) }
      ::spawn { pump(stderr, :stderr, STDERR, tap) }
    end

    private def pump(source : IO, stream : Symbol, mirror : IO, tap : Proc(Symbol, Bytes, Nil)) : Nil
      buffer = Bytes.new(4096)
      while (count = source.read(buffer)) > 0
        chunk = buffer[0, count].dup
        tap.call(stream, chunk)
        mirror.write(chunk)
      end
    rescue IO::Error
    ensure
      source.close
    end

    protected def self.posix_spawn(entry : String, args : Array(String), env : Hash(String, String), channel : IO::FileDescriptor | Socket,
                                   outputs : Tuple(IO::FileDescriptor, IO::FileDescriptor)?) : Int64
      actions = Pointer(UInt64).malloc(64).as(Void*)
      attr = Pointer(UInt64).malloc(64).as(Void*)
      check(LibChordSpawn.posix_spawn_file_actions_init(actions), "posix_spawn_file_actions_init")
      check(LibChordSpawn.posix_spawnattr_init(attr), "posix_spawnattr_init")
      begin
        null = File.open(File::NULL, "r")
        source = channel.fd
        source = LibC.fcntl(source, LibChordSpawn::F_DUPFD_CLOEXEC, CHANNEL_FD + 1) if source == CHANNEL_FD
        begin
          check(LibChordSpawn.posix_spawn_file_actions_adddup2(actions, null.fd, 0), "adddup2 stdin")
          if pipes = outputs
            check(LibChordSpawn.posix_spawn_file_actions_adddup2(actions, pipes[0].fd, 1), "adddup2 stdout")
            check(LibChordSpawn.posix_spawn_file_actions_adddup2(actions, pipes[1].fd, 2), "adddup2 stderr")
          end
          check(LibChordSpawn.posix_spawn_file_actions_adddup2(actions, source, CHANNEL_FD), "adddup2 channel")
          mask = uninitialized LibC::SigsetT
          LibC.sigemptyset(pointerof(mask))
          defaults = uninitialized LibC::SigsetT
          LibC.sigfillset(pointerof(defaults))
          LibC.sigdelset(pointerof(defaults), Signal::KILL.value)
          LibC.sigdelset(pointerof(defaults), Signal::STOP.value)
          check(LibChordSpawn.posix_spawnattr_setsigmask(attr, pointerof(mask)), "setsigmask")
          check(LibChordSpawn.posix_spawnattr_setsigdefault(attr, pointerof(defaults)), "setsigdefault")
          check(LibChordSpawn.posix_spawnattr_setpgroup(attr, 0), "setpgroup")
          flags = LibChordSpawn::POSIX_SPAWN_SETPGROUP | LibChordSpawn::POSIX_SPAWN_SETSIGDEF | LibChordSpawn::POSIX_SPAWN_SETSIGMASK
          check(LibChordSpawn.posix_spawnattr_setflags(attr, flags.to_i16), "setflags")
          argv = ([entry] + args).map(&.to_unsafe) + [Pointer(UInt8).null]
          envp = env.map { |key, value| "#{key}=#{value}".to_unsafe } + [Pointer(UInt8).null]
          pid = uninitialized LibC::PidT
          error = LibChordSpawn.posix_spawnp(pointerof(pid), entry, actions, attr, argv.to_unsafe, envp.to_unsafe)
          raise RuntimeError.from_os_error("Error executing process: '#{entry}'", Errno.new(error)) unless error == 0
          pid.to_i64
        ensure
          LibC.close(source) unless source == channel.fd
          null.close
        end
      ensure
        LibChordSpawn.posix_spawn_file_actions_destroy(actions)
        LibChordSpawn.posix_spawnattr_destroy(attr)
      end
    end

    private def self.check(result : LibC::Int, what : String) : Nil
      raise RuntimeError.from_os_error(what, Errno.new(result)) unless result == 0
    end
  end

  def self.fork_driver(entry : String, args = [] of String, env = {} of String => String, init = nil, lock : String? = nil,
                       on_output : Proc(Symbol, Bytes, Nil)? = nil, on_message : Proc(JSON::Any, Nil)? = nil) : ForkDriver
    ForkDriver.new(entry, args.map(&.to_s), env.to_h { |key, value| {key.to_s, value.to_s} }, init.nil? ? nil : json_value(init),
      lock, on_output, on_message)
  end

  class HostManager
    enum Status
      Stopped
      Starting
      Running
      Stopping

      def label : String
        to_s.downcase
      end
    end

    getter status = Status::Stopped
    getter instance : Instance? = nil
    @mutex = Mutex.new
    @active_calls = 0
    @viewers = 0
    @durable_tasks = 0
    @idle_since : Time::Instant? = nil
    @booting = false
    @ticker = 0

    def initialize(@driver : Driver, @keep_alive : Proc(Liveness, Bool)? = nil, @check_interval : Time::Span = 1.second,
                   @grace : Time::Span = 5.seconds, @ready_timeout : Time::Span = 30.seconds,
                   @on_exit : Proc(Exit, Nil)? = nil)
    end

    def liveness : Liveness
      since = @idle_since
      Liveness.new(@booting, @active_calls, @viewers, @durable_tasks, since ? Time.instant - since : Time::Span.zero)
    end

    def start : Instance
      @mutex.synchronize { do_start }
    end

    def stop : Nil
      @mutex.synchronize { do_stop }
    end

    def replace : Instance
      @mutex.synchronize do
        do_stop
        do_start
      end
    end

    private def do_start : Instance
      if (current = @instance) && @status.running?
        return current
      end
      @status = Status::Starting
      @booting = true
      @active_calls = @viewers = @durable_tasks = 0
      current = begin
        @driver.spawn
      rescue error
        @status = Status::Stopped
        @booting = false
        raise error
      end
      @instance = current
      current.exited.on_settle { exited(current) }
      begin
        await_ready(current)
      rescue error
        current.kill_tree
        current.exited.await_settled
        raise error
      end
      @booting = false
      @idle_since ||= Time.instant if busy == 0
      @status = Status::Running
      start_ticker
      current
    end

    private def await_ready(current : Instance) : Nil
      ready = Future(Nil).new
      current.exited.on_settle do
        exit = current.exited.wait
        ready.reject(ChordError.new(ErrorCode::Unavailable, "child exited before ready (#{exit.code || exit.signal})"))
      end
      current.on_control { |message| control(message, ready) }
      if ready.wait([] of AbortSignal, @ready_timeout).timed_out?
        raise ChordError.new(ErrorCode::Unavailable, "child not ready in time")
      end
      ready.wait
    end

    private def control(message : ControlMessage, ready : Future(Nil)) : Nil
      case message.type
      when "ready"
        ready.resolve(nil)
      when "fatal"
        ready.reject(ChordError.new(ErrorCode::Unavailable, "child failed: #{message.message}", reason: message.reason))
      when "status"
        @active_calls = message.active_calls || 0
        @viewers = message.viewers || 0
        @durable_tasks = message.durable_tasks || 0
        if busy > 0
          @idle_since = nil
        else
          @idle_since ||= Time.instant
        end
      end
    end

    private def busy : Int32
      @active_calls + @viewers + @durable_tasks
    end

    private def exited(current : Instance) : Nil
      if @instance.same?(current)
        @instance = nil
        @status = Status::Stopped
        @ticker += 1
      end
      @on_exit.try &.call(current.exited.wait)
    end

    private def do_stop : Nil
      current = @instance
      unless current
        @status = Status::Stopped
        @booting = false
        return
      end
      @status = Status::Stopping
      @ticker += 1
      current.send(ControlMessage.new("shutdown"))
      current.kill_tree if current.exited.wait([] of AbortSignal, @grace).timed_out?
      current.exited.await_settled
      @instance = nil if @instance.same?(current)
      @status = Status::Stopped
    end

    private def start_ticker : Nil
      keep_alive = @keep_alive
      return unless keep_alive
      @ticker += 1
      ticker = @ticker
      ::spawn { tick(ticker, keep_alive) }
    end

    private def tick(ticker : Int32, keep_alive : Proc(Liveness, Bool)) : Nil
      loop do
        sleep @check_interval
        return unless ticker == @ticker
        if @status.running? && !keep_alive.call(liveness)
          ::spawn { stop }
          return
        end
      end
    end
  end

  def self.create_host_manager(driver : Driver, keep_alive : Proc(Liveness, Bool)? = nil, check_interval : Time::Span = 1.second,
                               grace : Time::Span = 5.seconds, ready_timeout : Time::Span = 30.seconds,
                               on_exit : Proc(Exit, Nil)? = nil) : HostManager
    HostManager.new(driver, keep_alive, check_interval, grace, ready_timeout, on_exit)
  end

  class ChildControl
    getter channel : IpcChannel
    getter init = Future(JSON::Any?).new
    @shutdown = [] of Proc(Nil)
    @release : Proc(Nil)? = nil

    def initialize(@channel : IpcChannel)
      @channel.on_message { |message| on_message(message) }
      @channel.start
    end

    def lock : Nil
      name = ENV[LOCK_ENV]?
      return unless name
      @release = Chord.process_lock(name)
    rescue error
      fatal(error)
      raise error
    end

    def ready : Nil
      send(ControlMessage.new("ready"))
    end

    def fatal(error : Exception) : Nil
      reason = error.is_a?(ChordError) ? error.reason : nil
      send(ControlMessage.new("fatal", message: error.is_a?(ChordError) ? error.message.try(&.sub(/^[a-z_]+(\/[a-z_]+)?: /, "")) : error.message, reason: reason))
    end

    def report(active_calls : Int32? = nil, viewers : Int32? = nil, durable_tasks : Int32? = nil) : Nil
      send(ControlMessage.new("status", active_calls: active_calls, viewers: viewers, durable_tasks: durable_tasks))
    end

    def on_shutdown(&handler : -> Nil) : Nil
      @shutdown << handler
    end

    def link : IpcLink
      IpcLink.new(@channel)
    end

    private def send(message : ControlMessage) : Nil
      @channel.send_line(message.wire) if @channel.connected?
    end

    private def on_message(message : JSON::Any) : Nil
      control = ControlMessage.from(message)
      return unless control
      case control.type
      when "init"     then @init.resolve(control.value)
      when "shutdown" then @shutdown.each { |handler| ::spawn { handler.call } }
      end
    end
  end

  def self.child_control(channel : IpcChannel? = nil) : ChildControl
    ChildControl.new(channel || IpcChannel.from_env || raise ArgumentError.new("child_control needs an IPC channel (NODE_CHANNEL_FD)"))
  end

  def self.process_lock(name : String) : Proc(Nil)
    key = Digest::SHA256.hexdigest(name)[0, 32]
    {% if flag?(:linux) %}
      abstract_lock(name, "\0chord2-#{key}")
    {% else %}
      file_lock(name, File.join(Dir.tempdir, "chord2-#{key}.sock"))
    {% end %}
  end

  private def self.abstract_lock(name : String, address : String) : Proc(Nil)
    socket = Socket.new(Socket::Family::UNIX, Socket::Type::STREAM)
    sockaddr = LibC::SockaddrUn.new
    sockaddr.sun_family = LibC::AF_UNIX.to_u16
    bytes = address.to_slice
    bytes.each_with_index { |byte, index| sockaddr.sun_path[index] = byte }
    length = offsetof(LibC::SockaddrUn, @sun_path) + bytes.size
    if LibC.bind(socket.fd, pointerof(sockaddr).as(LibC::Sockaddr*), length) != 0
      errno = Errno.value
      socket.close
      raise locked(name) if errno == Errno::EADDRINUSE
      raise RuntimeError.from_os_error("bind #{name}", errno)
    end
    socket.listen
    spawn { refuse(socket) }
    lock_releaser(socket)
  end

  private def self.file_lock(name : String, path : String) : Proc(Nil)
    loop do
      begin
        server = UNIXServer.new(path)
        spawn { refuse(server) }
        return lock_releaser(server, path)
      rescue error : Socket::BindError
        raise locked(name) if accepting?(path)
        File.delete?(path)
      end
    end
  end

  private def self.accepting?(path : String) : Bool
    UNIXSocket.new(path).close
    true
  rescue Socket::ConnectError
    false
  end

  private def self.refuse(server : Socket) : Nil
    while client = server.accept?
      client.close
    end
  rescue IO::Error
  end

  private def self.lock_releaser(server : Socket, path : String? = nil) : Proc(Nil)
    -> { server.close rescue nil; path.try { |file| File.delete?(file) }; nil }
  end

  private def self.locked(name : String) : ChordError
    ChordError.new(ErrorCode::Unavailable, "lock #{name} is held by another process", reason: "locked")
  end
end
