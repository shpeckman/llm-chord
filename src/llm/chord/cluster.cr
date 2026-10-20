# src/llm/chord/cluster.cr
module LLM::Chord
  @@reload_seq = 0

  private def self.modules_for(remote : Hash(String, Array(String))?, host_name : String?) : Array(String)
    best = nil.as(Tuple(String, Array(String))?)
    (remote || {} of String => Array(String)).each do |prefix, modules|
      if host_name.try(&.starts_with?(prefix)) && (best.nil? || prefix.size > best.not_nil![0].size)
        best = {prefix, modules}
      end
    end
    best.try(&.[1].dup) || [] of String
  end

  private def self.await_vote(connection : Connection, id : Int32, deadline : Int32) : Future(JSON::Any?)
    future = Future(JSON::Any?).new
    connection.votes[id] = future
    spawn do
      sleep deadline.milliseconds
      connection.votes.delete(id) if connection.votes[id]?.try(&.same?(future))
      future.reject(ChordError.new(ErrorCode::Aborted, "votes missing after #{deadline} ms", reason: "vote_deadline"))
    end
    future
  end

  private def self.report_from_json(json : JSON::Any) : ReloadReport
    ReloadReport.new(
      json["codeVersion"].as_i.to_i32,
      json["previous"].as_i.to_i32,
      json["changed"].as_a.map(&.as_s),
      json["removed"].as_a.map(&.as_s),
      json["prepared"].as_a.map(&.as_s),
      json["gated"].as_a.map(&.as_s),
    )
  end

  private def self.prepare_frame_options(options : ReloadOptions, host_name : String?) : Hash(String, JSON::Any)
    result = {} of String => JSON::Any
    result["remove"] = Frame.json(modules_for(options.remote_remove, host_name))
    result["gateDeadline"] = Frame.json(options.gate_deadline.not_nil!) if options.gate_deadline
    result["retireDeadline"] = Frame.json(options.retire_deadline.not_nil!) if options.retire_deadline
    result
  end

  def self.run_cluster_reload(host : Host, plugins : Array(Facet), options : ReloadOptions) : ReloadReport
    synced = host.connections.select do |connection|
      connection.role.downstream? && connection.peer.kind.host? && connection.open? && connection.synced?
    end
    code_version = host.peek_next_code_version
    reload = begin_reload(host, plugins, options, code_version)
    begin
      reload.wait_for_retirement
      participants = synced.select(&.open?)
      id = @@reload_seq += 1
      deadline = options.vote_deadline || (options.gate_deadline || 5000) + (options.retire_deadline || 5000) + 5000
      votes = [] of Tuple(String, Future(JSON::Any?))
      participants.each do |connection|
        name = connection.name || "child"
        vote = await_vote(connection, id, deadline)
        connection.send(Frame.build("prepare", reload: id, codeVersion: code_version,
          plugins: modules_for(options.remote, name), options: prepare_frame_options(options, name)))
        votes << {name, vote}
      end
      local = false
      local_future = Future(Nil).run do
        reload.prepare
        local = true
        nil
      end
      local_future.await_settled
      errors = [] of Exception
      errors << local_future.error.not_nil! if local_future.error
      votes.each do |(name, vote)|
        vote.await_settled
        if error = vote.error
          cause = Chord.reload_error(error)
          errors << ChordError.new(cause.code, "#{name}: #{cause.message}", cause: cause, reason: cause.reason)
        end
      end
      unless errors.empty?
        participants.each do |connection|
          connection.votes.delete(id)
          connection.send(Frame.build("abort", reload: id))
        end
        reload.rollback if local
        raise errors[0]
      end
      report = reload.commit(-> do
        participants.each do |connection|
          connection.send(Frame.build("commit", reload: id))
          connection.peer_code_version = code_version
        end
      end)
      host.remember_remote_modules(options.remote, options.remote_remove)
      children = {} of String => ReloadReport
      votes.each do |(name, vote)|
        if json = vote.wait
          children[name] = report_from_json(json)
        end
      end
      ReloadReport.new(report.code_version, report.previous, report.changed, report.removed,
        report.prepared, report.gated, children)
    ensure
      end_reload(host)
    end
  end

  def self.reconcile_child(host : Host, connection : Connection) : Nil
    loop do
      return unless connection.open?
      if host.reloading
        host.when_reload_ended.wait
        next
      end
      code_version = host.current.id
      if connection.peer_code_version == code_version
        connection.mark_synced(code_version)
        host.announce_retired(connection)
        return
      end
      host.announce_retired(connection)
      id = @@reload_seq += 1
      vote = await_vote(connection, id, 30_000)
      options = {} of String => JSON::Any
      options["remove"] = Frame.json(modules_for(host.remote_removed, connection.name))
      connection.send(Frame.build("prepare", reload: id, codeVersion: code_version,
        plugins: modules_for(host.remote_modules, connection.name), options: options))
      vote.wait
      if host.current.id != code_version
        connection.send(Frame.build("abort", reload: id))
        next
      end
      connection.send(Frame.build("commit", reload: id))
      connection.peer_code_version = code_version
    end
  end

  private class ChildOperation
    getter id : Int32
    property reload : Reload?
    property state : Symbol = :loading
    property cancelled : Bool = false

    def initialize(@id : Int32); end
  end

  class ChildReloads
    def initialize(@host : Host); end

    @operation : ChildOperation? = nil

    def handle(connection : Connection, frame : Frame) : Nil
      if frame.t == "prepare"
        if @operation
          error = ChordError.new(ErrorCode::Unavailable, "a reload is already running", reason: "reload_running")
          connection.send(Frame.build("vote", reload: frame.int("reload"), error: Wire.to_error(error)))
          return
        end
        operation = ChildOperation.new(frame.int("reload").to_i32)
        @operation = operation
        spawn do
          begin
            run(operation, connection, frame)
          rescue error
            @host.report(error)
          end
        end
        return
      end
      operation = @operation
      return unless operation && operation.id == frame.int("reload").to_i32
      if frame.t == "abort"
        cancel(operation)
        return
      end
      return unless operation.state == :prepared
      @operation = nil
      begin
        operation.reload.try(&.commit)
      ensure
        Chord.end_reload(@host)
      end
    end

    def parent_lost : Nil
      cancel(@operation.not_nil!) if @operation
    end

    private def cancel(operation : ChildOperation) : Nil
      operation.cancelled = true
      if operation.state != :prepared
        begin
          operation.reload.try(&.rollback)
        rescue error
          @host.report(error)
        end
        return
      end
      @operation = nil
      begin
        operation.reload.try(&.rollback)
      rescue error
        @host.report(error)
      ensure
        Chord.end_reload(@host)
      end
    end

    private def run(operation : ChildOperation, connection : Connection, frame : Frame) : Nil
      cancelled = -> { ChordError.new(ErrorCode::Aborted, "reload aborted by the server", reason: "aborted") }
      begin
        plugins = @host.resolve(frame["plugins"].as_a.map(&.as_s))
        options_json = frame["options"]?
        options = ReloadOptions.new(
          remove: options_json.try { |o| o["remove"]?.try(&.as_a.map(&.as_s)) },
          gate_deadline: options_json.try { |o| o["gateDeadline"]?.try(&.as_i.to_i32) },
          retire_deadline: options_json.try { |o| o["retireDeadline"]?.try(&.as_i.to_i32) },
        )
        operation.reload = Chord.begin_reload(@host, plugins, options, frame.int("codeVersion").to_i32)
        raise cancelled.call if operation.cancelled
        operation.state = :preparing
        operation.reload.not_nil!.prepare
        raise cancelled.call if operation.cancelled
        operation.state = :prepared
        connection.send(Frame.build("vote", reload: frame.int("reload"),
          report: JSON::Any.new(summary_to_json(operation.reload.not_nil!.summary))))
      rescue error
        if operation.reload
          begin
            operation.reload.not_nil!.rollback
          rescue cleanup
            @host.report(cleanup)
          end
          Chord.end_reload(@host)
        end
        @operation = nil if @operation.same?(operation)
        unless operation.cancelled
          connection.send(Frame.build("vote", reload: frame.int("reload"), error: Wire.to_error(error)))
        end
      end
    end

    private def summary_to_json(report : ReloadReport) : Hash(String, JSON::Any)
      {
        "codeVersion" => JSON::Any.new(report.code_version.to_i64),
        "previous"    => JSON::Any.new(report.previous.to_i64),
        "changed"     => Frame.json(report.changed),
        "removed"     => Frame.json(report.removed),
        "prepared"    => Frame.json(report.prepared),
        "gated"       => Frame.json(report.gated),
      }
    end
  end
end
