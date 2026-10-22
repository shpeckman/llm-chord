# src/llm-chord/cluster.cr
module LLM::Chord
  module Cluster
    RECONCILE_DEADLINE = 30.seconds

    @@reload_seq = 0_i64

    protected def self.reload(host : Host, plugins : Enumerable, options : ReloadOptions) : ReloadReport
      synced = host.connections.select do |connection|
        connection.role.downstream? && connection.peer.kind.host? && connection.open? && connection.synced?
      end
      code_version = host.peek_next_code_version
      reload = Reload.start(host, plugins, options, code_version)
      begin
        reload.wait_for_retirement
        participants = synced.select(&.open?)
        id = @@reload_seq += 1
        deadline = options.votes
        votes = participants.map do |connection|
          name = connection.name || "child"
          vote = Future(JSON::Any?).new
          connection.votes[id] = vote
          connection.send(prepare(id, code_version, modules_for(options.remote, name),
            options.to_wire(modules_for(options.remote_remove, name))))
          Future(Tuple(String, ReloadReport?)).run { collect(connection, id, name, vote, deadline) }
        end
        local = Future(Nil).run { reload.prepare }
        local.await_settled
        votes.each(&.await_settled)
        failure = local.error || votes.compact_map(&.error).first?
        if failure
          participants.each do |connection|
            connection.votes.delete(id)
            connection.send(Frame.build("abort", reload: id))
          end
          reload.rollback unless local.rejected?
          raise failure
        end
        report = reload.commit(committer(participants, id, code_version))
        host.remember_remote_modules(options.remote, options.remote_remove)
        children = {} of String => ReloadReport
        votes.each do |vote|
          name, child = vote.wait
          children[name] = child if child
        end
        report.with_children(children)
      ensure
        host.reload_ended
      end
    end

    protected def self.reconcile_or_close(host : Host, connection : Connection) : Nil
      reconcile(host, connection)
    rescue error
      host.report(error)
      connection.link.close("reconciliation failed")
    end

    protected def self.modules_for(remote : Hash(String, Array(String))?, host_name : String?) : Array(String)
      return [] of String unless remote && host_name
      chosen = ""
      found = nil.as(Array(String)?)
      remote.each do |prefix, modules|
        next unless host_name.starts_with?(prefix)
        next if found && prefix.size <= chosen.size
        chosen = prefix
        found = modules
      end
      found.try(&.dup) || [] of String
    end

    private def self.reconcile(host : Host, connection : Connection) : Nil
      loop do
        return unless connection.open?
        if host.reloading?
          host.when_reload_ended
          next
        end
        code_version = host.code_version
        if connection.peer_code_version == code_version
          connection.mark_synced(code_version)
          host.announce_retired(connection)
          return
        end
        host.announce_retired(connection)
        id = @@reload_seq += 1
        vote = Future(JSON::Any?).new
        connection.votes[id] = vote
        remove = modules_for(host.remote_removed, connection.name)
        connection.send(prepare(id, code_version, modules_for(host.remote_modules, connection.name),
          JSON::Any.new({"remove" => JSON::Any.new(remove.map { |name| JSON::Any.new(name) })})))
        if vote.wait(Array(AbortSignal).new, RECONCILE_DEADLINE).timed_out?
          connection.votes.delete(id)
          raise ChordError.new(ErrorCode::Aborted, "votes missing after #{Chord.milliseconds(RECONCILE_DEADLINE)} ms",
            reason: "vote_deadline")
        end
        vote.wait
        if host.code_version != code_version
          connection.send(Frame.build("abort", reload: id))
          next
        end
        connection.send(Frame.build("commit", reload: id))
        connection.peer_code_version = code_version
      end
    end

    private def self.collect(connection : Connection, id : Int64, name : String, vote : Future(JSON::Any?),
                             deadline : Time::Span) : Tuple(String, ReloadReport?)
      error = if vote.wait([] of AbortSignal, deadline).timed_out?
                connection.votes.delete(id)
                ChordError.new(ErrorCode::Aborted, "votes missing after #{Chord.milliseconds(deadline)} ms", reason: "vote_deadline")
              else
                vote.error
              end
      if error
        cause = Reload.error(error)
        raise ChordError.new(cause.code, "#{name}: #{cause.message}", reason: cause.reason, cause: cause)
      end
      {name, vote.wait.try { |report| ReloadReport.from_wire(report) }}
    end

    private def self.prepare(id : Int64, code_version : Int32, plugins : Array(String), options : JSON::Any) : Frame
      Frame.build("prepare", reload: id, codeVersion: code_version, plugins: plugins, options: options)
    end

    private def self.committer(participants : Array(Connection), id : Int64, code_version : Int32) : Proc(Nil)
      -> {
        participants.each do |connection|
          connection.send(Frame.build("commit", reload: id))
          connection.peer_code_version = code_version
        end
        nil
      }
    end
  end

  enum ChildState
    Loading
    Preparing
    Prepared
  end

  class ChildOperation
    getter id : Int64
    property reload : Reload? = nil
    property state = ChildState::Loading
    property? cancelled = false

    def initialize(@id : Int64); end
  end

  class ChildReloads
    @operation : ChildOperation? = nil

    def initialize(@host : Host); end

    protected def handle(connection : Connection, frame : Frame) : Nil
      id = frame.int("reload")
      if frame.t == "prepare"
        if @operation
          error = ChordError.new(ErrorCode::Unavailable, "a reload is already running", reason: "reload_running")
          connection.send(Frame.build("vote", reload: id, error: Wire.to_error(error)))
          return
        end
        started = ChildOperation.new(id)
        @operation = started
        spawn { run(started, connection, frame) }
        return
      end
      operation = @operation
      return if operation.nil? || operation.id != id
      if frame.t == "abort"
        cancel(operation)
        return
      end
      return unless operation.state.prepared?
      @operation = nil
      begin
        operation.reload.try &.commit
      ensure
        @host.reload_ended
      end
    end

    protected def parent_lost : Nil
      @operation.try { |operation| cancel(operation) }
    end

    private def run(operation : ChildOperation, connection : Connection, frame : Frame) : Nil
      cancelled = ChordError.new(ErrorCode::Aborted, "reload aborted by the server", reason: "aborted")
      plugins = frame["plugins"].as_a.map(&.as_s)
      reload = Reload.start(@host, plugins, ReloadOptions.from_wire(frame["options"]), frame.int("codeVersion").to_i32)
      operation.reload = reload
      raise cancelled if operation.cancelled?
      operation.state = ChildState::Preparing
      reload.prepare
      raise cancelled if operation.cancelled?
      operation.state = ChildState::Prepared
      connection.send(Frame.build("vote", reload: operation.id, report: reload.summary.to_wire))
    rescue error
      if started = operation.reload
        rollback(started)
        @host.reload_ended
      end
      @operation = nil if @operation.same?(operation)
      connection.send(Frame.build("vote", reload: operation.id, error: Wire.to_error(error))) unless operation.cancelled?
    end

    private def cancel(operation : ChildOperation) : Nil
      operation.cancelled = true
      unless operation.state.prepared?
        operation.reload.try { |reload| spawn { rollback(reload) } }
        return
      end
      @operation = nil
      operation.reload.try { |reload| spawn { finish_cancel(reload) } }
    end

    private def finish_cancel(reload : Reload) : Nil
      rollback(reload)
    ensure
      @host.reload_ended
    end

    private def rollback(reload : Reload) : Nil
      reload.rollback
    rescue error
      @host.report(error)
    end
  end
end
