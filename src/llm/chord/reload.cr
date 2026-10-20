# src/llm/chord/reload.cr
module LLM::Chord
  class ReloadOptions
    getter remove : Array(String)?
    getter gate_deadline : Int32?
    getter retire_deadline : Int32?
    getter remote : Hash(String, Array(String))?
    getter remote_remove : Hash(String, Array(String))?
    getter vote_deadline : Int32?

    def initialize(@remove : Array(String)? = nil, @gate_deadline : Int32? = nil, @retire_deadline : Int32? = nil,
                   @remote : Hash(String, Array(String))? = nil, @remote_remove : Hash(String, Array(String))? = nil,
                   @vote_deadline : Int32? = nil)
    end
  end

  class ReloadReport
    getter code_version : Int32
    getter previous : Int32
    getter changed : Array(String)
    getter removed : Array(String)
    getter prepared : Array(String)
    getter gated : Array(String)
    getter children : Hash(String, ReloadReport)?

    def initialize(@code_version : Int32, @previous : Int32, @changed : Array(String), @removed : Array(String),
                   @prepared : Array(String), @gated : Array(String), @children : Hash(String, ReloadReport)? = nil)
    end
  end

  class Candidate
    getter object : ObjectImpl
    getter service : Service
    getter run : Run
    getter reasons = [] of String
    getter at_gate = [] of AnyResource
    getter replaced = [] of AnyResource
    getter migrated = {} of Cell => JSON::Any
    property derived = {} of Readable => JSON::Any
    property staged : StagedListeners? = nil

    def initialize(@object : ObjectImpl, @service : Service, @run : Run); end
  end

  class Reload
    getter host : Host
    getter facets : Array(Facet)
    getter options : ReloadOptions
    getter code_version : Int32?
    getter candidates = {} of ObjectImpl => Candidate
    getter abort = AbortController.new
    getter closed = [] of Tuple(ObjectImpl, AnyResource)
    @services = {} of String => Service
    @changed = ::Set(String).new
    @removed = ::Set(String).new
    @tables = {} of String => RegistryTable
    @gated = [] of Candidate
    @rolled_back = false
    @deferred = {} of ObjectImpl => StagedListeners
    @facet_runs = {} of String => AbortController
    @starts = [] of Proc(Nil)

    def initialize(@host : Host, @facets : Array(Facet), @options : ReloadOptions, @code_version : Int32? = nil); end

    def prepare : Nil
      wait_for_retirement
      load
      check_providers
      prepare_all
      @host.gating = @changed.dup
      with_deadline("activations in flight did not finish") { prepare_all }
      check_refs
      @tables = @host.build_tables(entries)
      gate
      alive
      stage
    rescue error
      rollback
      raise Chord.reload_error(error)
    end

    def summary : ReloadReport
      live = @candidates.values.select { |candidate| candidate.object.status.live? }
      ReloadReport.new(@host.pending.try(&.id) || @host.current.id, @host.current.id,
        @changed.to_a, @removed.to_a, live.map(&.object.address), @gated.map(&.object.address))
    end

    def commit(before_start : Proc(Nil)? = nil) : ReloadReport
      Publish.hold do
        report = publish
        before_start.try(&.call)
        starts = @starts
        @starts = [] of Proc(Nil)
        starts.each(&.call)
        report
      end
    rescue error
      @host.fail(error)
      raise Chord.reload_error(error)
    end

    private def alive : Nil
      raise ChordError.new(ErrorCode::Aborted, "reload aborted while preparing", reason: "aborted") if @rolled_back
    end

    private def stage : Nil
      @candidates.each_value do |candidate|
        candidate.staged = candidate.object.stage_listeners(candidate.run.decls) if candidate.object.status.live?
      end
      @host.objects.values.each do |object|
        @deferred[object] = object.stage_listeners(object.decls) if object.status.live? && object.deferred_runtime
      end
    end

    protected def wait_for_retirement : Nil
      host = @host
      previous = host.previous
      return unless previous
      deadline = @options.retire_deadline || 5000
      gone = -> { host.previous.try(&.id) != previous.id }
      unless Chord.until(host, -> { gone.call || host.retirable? }, deadline) && !gone.call
        previous.abort.abort(ChordError.new(ErrorCode::Superseded, "code version #{previous.id} was retired"))
        Chord.until(host, -> { gone.call || previous.roots.empty? }, Math.min(deadline, Chord::ABORTED_ROOTS_GRACE))
      end
      host.retire unless gone.call
    end

    private def load : Nil
      replaced = ::Set(String).new
      @facets.each { |facet| replaced << facet.name }
      (@options.remove || [] of String).each { |name| replaced << name }
      current = @host.current.services
      @services = {} of String => Service
      current.each do |name, service|
        @services[name] = service unless replaced.includes?(service.facet)
      end
      @facets.each do |facet|
        run = AbortController.new
        @facet_runs[facet.name] = run
        facet.setup.call(@host.facet_api(facet.name, run.signal, [] of Service, @services))
      end
      @services.each { |name, service| @changed << name unless current[name]?.try(&.same?(service)) }
      current.each_key { |name| @removed << name unless @services.has_key?(name) }
      @host.pending = CodeVersionState.new(@host.next_code_version_id(@code_version), @services,
        {} of String => RegistryTable, {} of String => Int32, AbortController.new)
    end

    private def with_deadline(what : String, &work : ->) : Nil
      deadline = @options.gate_deadline || 5000
      future = Future(Nil).run { work.call }
      if future.wait([] of AbortSignal, deadline.milliseconds).timed_out?
        raise ChordError.new(ErrorCode::Aborted, "#{what} within #{deadline} ms", reason: "deadline")
      end
      future.wait
    end

    private def check_providers : Nil
      @changed.each do |name|
        next_contract = @services[name].not_nil!.contract
        old = @host.current.services[name]?.try(&.contract)
        next if old.nil? || old.version != next_contract.version
        reason = Chord.coverage(next_contract.description, old.description)
        if reason
          raise ChordError.new(ErrorCode::ContractMismatch,
            "#{name}@#{next_contract.version} changed incompatibly without a version bump (#{reason})")
        end
      end
      facets = @host.facets.dup
      @facets.each { |facet| facets[facet.name] = facet }
      (@options.remove || [] of String).each { |name| facets.delete(name) }
      facets.each_value do |facet|
        facet.uses.each do |token|
          service = @services[token.name]?
          Chord.bind(service.contract, service.accepts, token) if service && @changed.includes?(token.name)
        end
      end
    end

    private def prepare_all : Nil
      loop do
        todo = @host.objects.values.select do |object|
          @changed.includes?(object.type_name) &&
            !@candidates.has_key?(object) &&
            !object.service.same?(@services[object.type_name]?) &&
            (object.status.live? || object.status.activating?)
        end
        return if todo.empty?
        todo.each(&.ready.await_settled)
        alive
        todo.each do |object|
          if object.status.live? && !object.service.same?(@services[object.type_name]?)
            prepare_object(object)
            alive
          end
        end
      end
    end

    private def prepare_object(object : ObjectImpl) : Nil
      service = @services[object.type_name].not_nil!
      run = object.run(service, object.decls)
      candidate = Candidate.new(object, service, run)
      @candidates[object] = candidate
      run.decls.cells.each do |name, cell|
        next unless object.decls.cells[name]?.try(&.same?(cell))
        from = object.decls.cell_versions[name]? || 1
        to = run.decls.cell_versions[name]? || 1
        if to < from
          raise Chord.invalid("state", "#{object.address}: version of state #{name} lowered from #{from} to #{to}")
        end
        if to > from
          candidate.reasons << "state #{name} version #{from} -> #{to}"
        elsif !Schema.deep_equal?(cell.schema, run.decls.cell_schemas[name])
          raise Chord.invalid("state", "#{object.address}: schema of state #{name} changed without a version bump")
        end
      end
      deferred = ::Set(AnyResource).new
      run.created_resources.each do |resource|
        deferred << resource if resource.exclusive? || resource.deps.any? { |dep| dep.is_a?(AnyResource) && deferred.includes?(dep) }
      end
      deferred.each do |resource|
        candidate.at_gate << resource
        old = object.decls.resources[resource.key]?
        candidate.replaced << old if resource.exclusive? && old.try(&.exclusive?) && old.state.open?
      end
      candidate.reasons << "exclusive resource replaced" if deferred.size > 0
      object.open(run.created_resources.reject { |resource| deferred.includes?(resource) }, run.created_refs, @abort.signal)
      object.wait_hydrated(run)
      if candidate.reasons.empty?
        object.init_cells(run, @abort.signal)
        dry_run(candidate)
      end
    end

    private def dry_run(candidate : Candidate) : Nil
      run = candidate.run
      service = candidate.service
      object = candidate.object
      exposed = Chord.member_schemas(service, run.implementation.not_nil!)
      candidate.migrated.each do |cell, value|
        (exposed[cell]? || [] of Schema::Source).each do |schema|
          Schema.assert_valid("state", "#{object.address}: migrated state #{cell.key}", schema, value)
        end
      end
      values = {} of Readable => JSON::Any
      candidate.migrated.each { |cell, value| values[cell] = value }
      run.decls.derives.values.sort_by(&.seq).each do |derived|
        value = derived.compute { |source| values.has_key?(source) ? values[source] : candidate_value(source) }
        (exposed[derived]? || [] of Schema::Source).each do |schema|
          Schema.assert_valid("state", "#{object.address}: derivation #{derived.key}", schema, value)
        end
        values[derived] = value
      end
      candidate.derived = values
    end

    private def candidate_value(source : Readable) : JSON::Any
      source.value
    rescue error
      if Chord.chord_error?(error, ErrorCode::NotReady) || Chord.chord_error?(error, ErrorCode::NotInVariant)
        return JSON::Any.new(nil)
      end
      raise error
    end

    private def check_refs : Nil
      dropped = ::Set(Ref).new
      @candidates.each_value do |candidate|
        object = candidate.object
        run = candidate.run
        object.decls.refs.each_value do |ref|
          dropped << ref unless run.decls.refs.values.any?(&.same?(ref))
        end
      end
      @host.objects.values.each do |object|
        service = @services[object.type_name]?
        next if service.nil? || !@changed.includes?(object.type_name)
        object.refs.each do |ref|
          next if ref.same?(@host.host_objects[object.type_name]?)
          Chord.bind(service.contract, service.accepts, ref.contract) if !dropped.includes?(ref) && ref.owner != RefOwner::Client
        end
      end
    end

    private def entries : Array(Tuple(ObjectImpl, Decls))
      @host.live_decls(true)
        .reject { |(object, _)| @removed.includes?(object.type_name) }
        .map { |(object, decls)| {object, @candidates[object]?.try(&.run.decls) || decls} }
    end

    private def gate : Nil
      @gated = @candidates.values.select { |candidate| candidate.reasons.size > 0 && candidate.object.status.live? }
      drained = @gated.map do |candidate|
        object = candidate.object
        grandfathered = ::Set(String).new
        object.leases.each_key { |root_id| grandfathered << root_id }
        future = Future(Nil).new
        object.gate = Gate.new(grandfathered, -> { future.resolve(nil); nil })
        object.stop_tasks
        future.resolve(nil) if grandfathered.empty?
        future
      end
      deadline = @options.gate_deadline || 5000
      timed_out = false
      drained.each do |future|
        if future.wait([] of AbortSignal, deadline.milliseconds).timed_out?
          timed_out = true
          break
        end
      end
      if timed_out
        blocking = @gated.flat_map { |candidate| candidate.object.gate.try(&.grandfathered).try(&.to_a) || [] of String }
        raise ChordError.new(ErrorCode::Aborted,
          "gate deadline (#{deadline} ms) missed; blocking roots: #{blocking.join(", ")}",
          reason: "gate_deadline", details: JSON::Any.new(blocking.map { |b| JSON::Any.new(b) }))
      end
      alive
      @gated.each do |candidate|
        object = candidate.object
        candidate.replaced.each do |old|
          @closed << {object, old}
          old.close(object.open_order)
        end
        object.open(candidate.at_gate, [] of Ref, @abort.signal)
        alive
        object.init_cells(candidate.run, @abort.signal)
        alive
      end
      @gated.each { |candidate| migrate(candidate) }
    end

    private def migrate(candidate : Candidate) : Nil
      object = candidate.object
      run = candidate.run
      run.decls.cells.each do |name, cell|
        next unless object.decls.cells[name]?.try(&.same?(cell))
        schema = run.decls.cell_schemas[name].not_nil!
        from = object.decls.cell_versions[name]? || 1
        fn = run.decls.cell_migrations[name]?
        value : JSON::Any?
        if (run.decls.cell_versions[name]? || 1) > from && !fn.nil?
          value = fn.call(Json.deep_copy(cell.value), from)
        elsif !Schema.deep_equal?(cell.schema, schema)
          value = cell.value
        else
          next
        end
        Schema.assert_valid("state", "#{object.address}: migrated state #{name}", schema, value)
        candidate.migrated[cell] = value
      end
      dry_run(candidate)
    end

    protected def rollback : Nil
      return if @rolled_back
      @rolled_back = true
      @abort.abort(ChordError.new(ErrorCode::Aborted, "reload aborted"))
      @facet_runs.each_value { |run| run.abort(ChordError.new(ErrorCode::Aborted, "reload aborted")) }
      report = ->(error : Exception) { @host.report(error) }
      @candidates.each_value { |candidate| candidate.staged.try(&.discard.call) }
      @deferred.each_value { |staged| staged.discard.call }
      @candidates.each_value do |candidate|
        object = candidate.object
        object.pending.delete(candidate.run.decls)
        begin
          object.unwind(candidate.run)
        rescue error
          report.call(error)
        end
      end
      @closed.each do |(object, resource)|
        next unless resource.state.closed?
        begin
          resource.open(AbortController.new.signal, object.open_order)
        rescue error
          resource.mark_unavailable
          report.call(ChordError.new(ErrorCode::Unavailable,
            "#{object.address}: resource #{resource.key} could not be restored", cause: error))
        end
      end
      @gated.each do |candidate|
        object = candidate.object
        next unless object.gate
        object.open_gate
        object.start_tasks
      end
      reason = ChordError.new(ErrorCode::Gone, "reload aborted; type not served")
      @host.objects.values.each do |object|
        next if @host.current.services.has_key?(object.type_name)
        begin
          object.dispose(true, reason).await_settled
        rescue error
          report.call(error)
        end
      end
      @host.pending = nil
      @host.gating = nil
    end

    private def publish : ReloadReport
      host = @host
      previous = host.current
      next_state = host.pending.not_nil!
      host.pending = nil
      host.code_versions[next_state.id] = next_state
      host.previous = previous
      host.current = next_state
      prepared = [] of String
      host.objects.values.each do |object|
        next if @removed.includes?(object.type_name)
        candidate = @candidates[object]?
        if candidate.nil?
          installed = object.implementations[previous.id]?
          if installed
            object.implementations[next_state.id] = Installed.new(next_state.id, installed.service,
              installed.implementation, installed.decls)
          end
          next
        end
        next unless object.status.live?
        install(candidate, next_state.id)
        prepared << object.address
      end
      @candidates.each do |object, candidate|
        next if object.status.live?
        candidate.staged.try(&.discard.call)
        object.pending.delete(candidate.run.decls)
        begin
          object.unwind(candidate.run)
        rescue error
          host.report(error)
        end
      end
      @deferred.each do |object, staged|
        unless object.status.live?
          staged.discard.call
          next
        end
        object.deferred_runtime = false
        staged.activate.call
        @starts << -> { object.start_tasks; nil }
      end
      host.install_tables(next_state, @tables, true)
      reason = ChordError.new(ErrorCode::Gone, "type no longer served")
      host.objects.values.each do |object|
        if @removed.includes?(object.type_name)
          begin
            object.dispose(true, reason).await_settled
          rescue error
            host.report(error)
          end
        end
      end
      @removed.each { |name| host.host_objects.delete(name) }
      @facets.each { |facet| host.facets[facet.name] = facet }
      (@options.remove || [] of String).each { |name| host.facets.delete(name) }
      @facet_runs.each { |name, run| @starts << -> { host.facet_run_changed(name, run); nil } }
      (@options.remove || [] of String).each { |name| @starts << -> { host.facet_run_changed(name, nil); nil } }
      host.gating = nil
      @services.each do |name, service|
        pinned = host.host_objects[name]?
        if service.host_lifetime? && @changed.includes?(name) && (pinned.nil? || !pinned.object.try(&.status.live?))
          @starts << -> { host.start_host_object(service); nil }
        end
        if !service.host_lifetime? && !pinned.nil?
          host.host_objects.delete(name)
          @starts << -> { pinned.release; nil }
        end
      end
      ReloadReport.new(next_state.id, previous.id, @changed.to_a, @removed.to_a, prepared,
        @gated.map(&.object.address))
    end

    private def install(candidate : Candidate, code_version : Int32) : Nil
      object = candidate.object
      run = candidate.run
      service = candidate.service
      gated = candidate.reasons.size > 0
      object.pending.delete(run.decls)
      object.stop_tasks
      if gated
        kept = ::Set(Derived).new
        run.decls.derives.each_value { |derived| kept << derived }
        object.decls.derives.each_value { |derived| derived.detach unless kept.includes?(derived) }
      end
      object.decls = run.decls
      object.service = service
      run.decls.adopted.each_value(&.call)
      object.implementations[code_version] = Installed.new(code_version, service, run.implementation.not_nil!, run.decls)
      if gated
        object.min_code_version = code_version
        object.implementations.keys.each do |old|
          @host.retire_implementation(object, old) if old != code_version
        end
      end
      object.refresh_schemas
      run.decls.cells.each do |name, cell|
        schema = run.decls.cell_schemas[name].not_nil!
        if candidate.migrated.has_key?(cell)
          cell.reset(candidate.migrated[cell], schema)
        else
          cell.schema = schema
        end
      end
      created = ::Set(Derived).new
      run.created_derives.each { |derived| created << derived }
      run.created_derives.each { |derived| derived.attach(candidate.derived) }
      run.decls.derives.each_value { |derived| derived.refresh unless created.includes?(derived) }
      candidate.staged.try(&.activate.call)
      @starts << -> { object.start_tasks; nil }
      object.open_gate
      pinned = @host.host_objects[object.type_name]?
      if pinned && pinned.object.try(&.same?(object)) && pinned.contract.fingerprint != service.contract.fingerprint
        replacement = LocalRef.new(object, service.contract, RefOwner::Host)
        object.add_ref(replacement)
        @host.host_objects[object.type_name] = replacement
        pinned.release
      end
      object.refs.to_a.each do |ref|
        if ref.owner == RefOwner::Client
          begin
            Chord.bind(service.contract, service.accepts, ref.contract)
          rescue error
            ref.gone(ChordError.new(ErrorCode::UpgradeRequired, "#{object.type_name} changed; reload the web facets", cause: error))
            object.release(ref)
            next
          end
        end
        ref.shape_changed
      end
    end
  end

  ABORTED_ROOTS_GRACE = 1000

  def self.run_reload(host : Host, facets : Array(Facet), options : ReloadOptions) : ReloadReport
    reload = begin_reload(host, facets, options)
    begin
      reload.prepare
      reload.commit
    ensure
      end_reload(host)
    end
  end

  def self.begin_reload(host : Host, facets : Array(Facet), options : ReloadOptions, code_version : Int32? = nil) : Reload
    if host.reloading
      raise ChordError.new(ErrorCode::Unavailable, "a reload is already running", reason: "reload_running")
    end
    host.reloading = true
    Reload.new(host, facets, options, code_version)
  rescue error
    host.reload_ended
    raise reload_error(error)
  end

  def self.end_reload(host : Host) : Nil
    host.reload_ended
  end

  def self.reload_error(error : Exception) : ChordError
    cause = Chord.as_chord_error(error, "reload")
    stripped = cause.message.to_s.sub(/\A[^:]*: /, "")
    return cause if stripped.starts_with?("reload aborted")
    ChordError.new(cause.code, "reload aborted: #{cause.message}", cause: cause, reason: cause.reason, details: cause.details)
  end

  def self.until(host : Host, ready : Proc(Bool), ms : Int32) : Bool
    return true if ready.call
    channel = Channel(Bool).new(1)
    stop = host.watch_retirement { channel.send(true) if ready.call }
    result = select
             when value = channel.receive
               value
             when timeout(ms.milliseconds)
               false
             end
    stop.call
    result
  end
end
