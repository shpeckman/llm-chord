# src/llm/chord/reload.cr
module LLM::Chord
  DEFAULT_GATE_DEADLINE   = 5.seconds
  DEFAULT_RETIRE_DEADLINE = 5.seconds
  ABORTED_ROOTS_GRACE     = 1.second

  struct ReloadOptions
    getter remove : Array(String)
    getter gate_deadline : Time::Span?
    getter retire_deadline : Time::Span?
    getter remote : Hash(String, Array(String))?
    getter remote_remove : Hash(String, Array(String))?
    getter vote_deadline : Time::Span?

    def initialize(remove : Enumerable(String)? = nil, @gate_deadline : Time::Span? = nil,
                   @retire_deadline : Time::Span? = nil, @remote : Hash(String, Array(String))? = nil,
                   @remote_remove : Hash(String, Array(String))? = nil, @vote_deadline : Time::Span? = nil)
      @remove = remove.try(&.to_a) || [] of String
    end

    def gate : Time::Span
      @gate_deadline || DEFAULT_GATE_DEADLINE
    end

    def retire : Time::Span
      @retire_deadline || DEFAULT_RETIRE_DEADLINE
    end

    def votes : Time::Span
      @vote_deadline || gate + retire + 5.seconds
    end

    def to_wire(remove : Array(String)) : JSON::Any
      fields = {"remove" => JSON::Any.new(remove.map { |name| JSON::Any.new(name) })}
      @gate_deadline.try { |span| fields["gateDeadline"] = JSON::Any.new(Chord.milliseconds(span)) }
      @retire_deadline.try { |span| fields["retireDeadline"] = JSON::Any.new(Chord.milliseconds(span)) }
      JSON::Any.new(fields)
    end

    def self.from_wire(options : JSON::Any) : ReloadOptions
      remove = options["remove"]?.try(&.as_a.map(&.as_s))
      new(remove, span(options["gateDeadline"]?), span(options["retireDeadline"]?))
    end

    private def self.span(value : JSON::Any?) : Time::Span?
      case raw = value.try(&.raw)
      when Int64   then raw.milliseconds
      when Float64 then raw.milliseconds
      end
    end
  end

  struct ReloadReport
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

    def with_children(children : Hash(String, ReloadReport)) : ReloadReport
      ReloadReport.new(@code_version, @previous, @changed, @removed, @prepared, @gated, children)
    end

    def to_wire : JSON::Any
      JSON::Any.new({
        "codeVersion" => JSON::Any.new(@code_version.to_i64),
        "previous"    => JSON::Any.new(@previous.to_i64),
        "changed"     => ReloadReport.strings(@changed),
        "removed"     => ReloadReport.strings(@removed),
        "prepared"    => ReloadReport.strings(@prepared),
        "gated"       => ReloadReport.strings(@gated),
      })
    end

    def self.from_wire(report : JSON::Any) : ReloadReport
      new(report["codeVersion"].as_i, report["previous"].as_i, names(report["changed"]), names(report["removed"]),
        names(report["prepared"]), names(report["gated"]))
    end

    protected def self.strings(values : Array(String)) : JSON::Any
      JSON::Any.new(values.map { |value| JSON::Any.new(value) })
    end

    private def self.names(values : JSON::Any) : Array(String)
      values.as_a.map(&.as_s)
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

    def gated? : Bool
      !@reasons.empty?
    end
  end

  class Reload
    getter host : Host
    getter facets : Array(Facet)
    getter options : ReloadOptions
    @code_version : Int32?
    @candidates = {} of ObjectImpl => Candidate
    @abort = AbortController.new
    @closed = [] of Tuple(ObjectImpl, AnyResource)
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

    protected def self.reload(host : Host, plugins : Enumerable, options : ReloadOptions) : ReloadReport
      reload = start(host, plugins, options)
      begin
        reload.prepare
        reload.commit
      ensure
        host.reload_ended
      end
    end

    protected def self.start(host : Host, plugins : Enumerable, options : ReloadOptions, code_version : Int32? = nil) : Reload
      if host.reloading?
        raise ChordError.new(ErrorCode::Unavailable, "a reload is already running", reason: "reload_running")
      end
      host.reloading = true
      begin
        new(host, host.resolve(plugins), options, code_version)
      rescue error
        host.reload_ended
        raise error(error)
      end
    end

    protected def self.error(error : Exception) : ChordError
      cause = Chord.as_chord_error(error, "reload")
      message = cause.message || ""
      return cause if message.sub(/^[^:]*: /, "").starts_with?("reload aborted")
      ChordError.new(cause.code, "reload aborted: #{message}", reason: cause.reason, details: cause.details, cause: cause)
    end

    protected def self.same_schema?(left : TypeBox::Schema, right : TypeBox::Schema?) : Bool
      !right.nil? && Schema.canonical_json(left) == Schema.canonical_json(right)
    end

    protected def self.candidate_value(source : Readable) : JSON::Any
      source.value
    rescue error : ChordError
      raise error unless error.code.not_ready? || error.code.not_in_variant?
      JSON::Any.new(nil)
    end

    protected def prepare : Nil
      wait_for_retirement
      load
      check_providers
      prepare_all
      @host.gating = @changed
      with_deadline("activations in flight did not finish") { prepare_all }
      check_refs
      @tables = @host.build_tables(entries)
      gate
      alive!
      stage
    rescue error
      rollback
      raise Reload.error(error)
    end

    protected def summary : ReloadReport
      live = @candidates.values.select(&.object.status.live?)
      ReloadReport.new(@host.pending.try(&.id) || @host.code_version, @host.code_version, @changed.to_a, @removed.to_a,
        live.map(&.object.address), @gated.map(&.object.address))
    end

    protected def wait_for_retirement : Nil
      host = @host
      previous = host.previous
      return unless previous
      deadline = @options.retire
      done = host.wait_retirement(deadline) { !host.previous.same?(previous) || host.retirable? }
      if !done && host.previous.same?(previous)
        previous.abort.abort(ChordError.new(ErrorCode::Superseded, "code version #{previous.id} was retired"))
        host.wait_retirement(Math.min(deadline, ABORTED_ROOTS_GRACE)) { !host.previous.same?(previous) || previous.roots.empty? }
      end
      host.retire if host.previous.same?(previous)
    end

    protected def rollback : Nil
      return if @rolled_back
      @rolled_back = true
      @abort.abort(ChordError.new(ErrorCode::Aborted, "reload aborted"))
      @facet_runs.each_value(&.abort(ChordError.new(ErrorCode::Aborted, "reload aborted")))
      @candidates.each_value { |candidate| candidate.staged.try(&.discard) }
      @deferred.each_value(&.discard)
      @candidates.each_value do |candidate|
        candidate.object.pending.delete(candidate.run.decls)
        unwind(candidate)
      end
      @closed.each { |(object, resource)| restore(object, resource) }
      @gated.each do |candidate|
        object = candidate.object
        next unless object.gate
        object.open_gate
        object.start_tasks
      end
      reason = ChordError.new(ErrorCode::Gone, "reload aborted; type not served")
      @host.objects.values.each do |object|
        next if @host.current.services.has_key?(object.type_name)
        disposal = object.dispose(true, reason)
        disposal.await_settled
        disposal.error.try { |error| @host.report(error) }
      end
      @host.pending = nil
      @host.gating = nil
    end

    protected def commit(before_start : Proc(Nil)? = nil) : ReloadReport
      Publish.hold do
        report = publish
        before_start.try &.call
        starts = @starts.dup
        @starts.clear
        starts.each(&.call)
        report
      end
    rescue error
      @host.fail(error)
      raise Reload.error(error)
    end

    private def alive! : Nil
      raise ChordError.new(ErrorCode::Aborted, "reload aborted while preparing", reason: "aborted") if @rolled_back
    end

    private def load : Nil
      replaced = @facets.map(&.name).to_set
      replaced.concat(@options.remove)
      current = @host.current.services
      @services = current.reject { |_, service| replaced.includes?(service.facet) }
      @facets.each do |facet|
        run = AbortController.new
        @facet_runs[facet.name] = run
        facet.setup.call(FacetApi.new(@host, facet.name, run.signal, sink))
      end
      @services.each { |name, service| @changed << name unless current[name]?.same?(service) }
      current.each_key { |name| @removed << name unless @services.has_key?(name) }
      @host.pending = CodeVersion.new(@host.next_code_version_id(@code_version), @services)
    end

    private def sink : ServeSink
      ->(service : Service) { @host.serve_into(@services, service) }
    end

    private def with_deadline(what : String, &work : -> Nil) : Nil
      deadline = @options.gate
      future = Future(Nil).run(&work)
      if future.wait([] of AbortSignal, deadline).timed_out?
        raise ChordError.new(ErrorCode::Aborted, "#{what} within #{Chord.milliseconds(deadline)} ms", reason: "deadline")
      end
      future.wait
    end

    private def check_providers : Nil
      @changed.each do |name|
        following = @services[name].contract
        old = @host.current.services[name]?.try(&.contract)
        next if old.nil? || old.version != following.version
        if reason = Chord.coverage(following.description, old.description)
          raise ChordError.new(ErrorCode::ContractMismatch,
            "#{name}@#{following.version} changed incompatibly without a version bump (#{reason})")
        end
      end
      facets = @host.facets.dup
      @facets.each { |facet| facets[facet.name] = facet }
      @options.remove.each { |name| facets.delete(name) }
      facets.each_value do |facet|
        facet.uses.each do |token|
          service = @services[token.name]?
          Chord.bind(service.contract, service.accepts, token) if service && @changed.includes?(token.name)
        end
      end
    end

    private def prepare_all : Nil
      loop do
        todo = @host.objects.values.select { |object| preparable?(object) }
        return if todo.empty?
        todo.each(&.ready.await_settled)
        alive!
        todo.each do |object|
          next unless object.status.live? && !object.service.same?(@services[object.type_name]?)
          prepare_object(object)
          alive!
        end
      end
    end

    private def preparable?(object : ObjectImpl) : Bool
      @changed.includes?(object.type_name) && !@candidates.has_key?(object) &&
        !object.service.same?(@services[object.type_name]?) && (object.status.live? || object.status.activating?)
    end

    private def prepare_object(object : ObjectImpl) : Nil
      service = @services[object.type_name]
      decls = object.decls
      run = object.run(service, decls)
      candidate = Candidate.new(object, service, run)
      @candidates[object] = candidate
      run.decls.cells.each do |name, cell|
        next unless decls.cells[name]?.same?(cell)
        from = decls.cell_versions[name]? || 1
        to = run.decls.cell_versions[name]? || 1
        if to < from
          raise Chord.invalid("state", "#{object.address}: version of state #{name} lowered from #{from} to #{to}")
        end
        if to > from
          candidate.reasons << "state #{name} version #{from} -> #{to}"
        elsif !Reload.same_schema?(cell.schema, run.decls.cell_schemas[name]?)
          raise Chord.invalid("state", "#{object.address}: schema of state #{name} changed without a version bump")
        end
      end
      deferred = ::Set(AnyResource).new
      run.created_resources.each do |resource|
        if resource.exclusive? || resource.deps.any? { |dep| dep.is_a?(AnyResource) && deferred.includes?(dep) }
          deferred << resource
        end
      end
      deferred.each do |resource|
        candidate.at_gate << resource
        old = decls.resources[resource.key]?
        candidate.replaced << old if resource.exclusive? && old && old.exclusive? && old.state.open?
      end
      candidate.reasons << "exclusive resource replaced" unless deferred.empty?
      object.open(run.created_resources.reject { |resource| deferred.includes?(resource) }, run.created_refs, @abort.signal)
      object.wait_hydrated(run)
      return if candidate.gated?
      object.init_cells(run, @abort.signal)
      dry_run(candidate)
    end

    private def dry_run(candidate : Candidate) : Nil
      run = candidate.run
      address = candidate.object.address
      exposed = Chord.member_schemas(candidate.service, run.implementation.not_nil!)
      values = {} of Readable => JSON::Any
      candidate.migrated.each do |cell, value|
        exposed[cell]?.try &.each { |schema| Schema.assert_valid("state", "#{address}: migrated state #{cell.key}", schema, value) }
        values[cell] = value
      end
      run.decls.derives.values.sort_by(&.seq).each do |derived|
        value = derived.compute { |source| values[source]? || Reload.candidate_value(source) }
        exposed[derived]?.try &.each { |schema| Schema.assert_valid("state", "#{address}: derivation #{derived.key}", schema, value) }
        values[derived] = value
      end
      candidate.derived = values
    end

    private def check_refs : Nil
      dropped = ::Set(Ref).new
      @candidates.each_value do |candidate|
        kept = candidate.run.decls.refs.values
        candidate.object.decls.refs.each_value { |ref| dropped << ref unless kept.any?(&.same?(ref)) }
      end
      @host.objects.each_value do |object|
        service = @services[object.type_name]?
        next if service.nil? || !@changed.includes?(object.type_name)
        own = @host.host_objects[object.type_name]?
        object.refs.each do |ref|
          next if ref.same?(own) || dropped.includes?(ref) || ref.owner.client?
          Chord.bind(service.contract, service.accepts, ref.contract)
        end
      end
    end

    private def entries : Array(Tuple(ObjectImpl, Decls))
      @host.live_decls(true)
        .reject { |(object, _)| @removed.includes?(object.type_name) }
        .map { |(object, decls)| {object, @candidates[object]?.try(&.run.decls) || decls} }
    end

    private def gate : Nil
      @gated = @candidates.values.select { |candidate| candidate.gated? && candidate.object.status.live? }
      drained = @gated.map do |candidate|
        object = candidate.object
        gate = Gate.new(object.leases.keys.to_set)
        object.gate = gate
        object.stop_tasks
        gate.drained
      end
      deadline = @options.gate
      unless Chord.settle_within(drained, deadline)
        blocking = @gated.flat_map { |candidate| candidate.object.gate.try(&.grandfathered.to_a) || [] of String }
        details = JSON::Any.new({"blocking" => JSON::Any.new(blocking.map { |root| JSON::Any.new(root) })})
        raise ChordError.new(ErrorCode::Aborted,
          "gate deadline (#{Chord.milliseconds(deadline)} ms) missed; blocking roots: #{blocking.join(", ")}",
          reason: "gate_deadline", details: details)
      end
      alive!
      @gated.each do |candidate|
        object = candidate.object
        candidate.replaced.each do |old|
          @closed << {object, old}
          old.close(object.open_order)
        end
        object.open(candidate.at_gate, [] of Ref, @abort.signal)
        alive!
        object.init_cells(candidate.run, @abort.signal)
        alive!
      end
      @gated.each { |candidate| migrate(candidate) }
    end

    private def migrate(candidate : Candidate) : Nil
      object = candidate.object
      decls = object.decls
      run = candidate.run
      run.decls.cells.each do |name, cell|
        next unless decls.cells[name]?.same?(cell)
        schema = run.decls.cell_schemas[name]
        from = decls.cell_versions[name]? || 1
        migration = run.decls.cell_migrations[name]?
        value = if (run.decls.cell_versions[name]? || 1) > from && migration
                  migration.call(Json.deep_copy(cell.value), from)
                elsif !Reload.same_schema?(cell.schema, schema)
                  cell.value
                else
                  next
                end
        Schema.assert_valid("state", "#{object.address}: migrated state #{name}", schema, value)
        candidate.migrated[cell] = value
      end
      dry_run(candidate)
    end

    private def stage : Nil
      @candidates.each_value do |candidate|
        object = candidate.object
        candidate.staged = object.stage_listeners(candidate.run.decls) if object.status.live?
      end
      @host.objects.each_value do |object|
        @deferred[object] = object.stage_listeners(object.decls) if object.status.live? && object.deferred_runtime?
      end
    end

    private def unwind(candidate : Candidate) : Nil
      candidate.object.unwind(candidate.run)
    rescue error
      @host.report(error)
    end

    private def restore(object : ObjectImpl, resource : AnyResource) : Nil
      return unless resource.state.closed?
      resource.open(AbortController.new.signal, object.open_order)
    rescue error
      resource.mark_unavailable
      @host.report(ChordError.new(ErrorCode::Unavailable, "#{object.address}: resource #{resource.key} could not be restored",
        cause: error))
    end

    private def publish : ReloadReport
      host = @host
      following = host.pending.not_nil!
      host.pending = nil
      previous = host.advance(following)
      prepared = [] of String
      host.objects.values.each do |object|
        next if @removed.includes?(object.type_name)
        candidate = @candidates[object]?
        unless candidate
          object.implementations[previous.id]?.try do |installed|
            object.implementations[following.id] = installed.copy_with(code_version: following.id)
          end
          next
        end
        next unless object.status.live?
        install(candidate, following.id)
        prepared << object.address
      end
      @candidates.each_value do |candidate|
        next if candidate.object.status.live?
        candidate.staged.try(&.discard)
        candidate.object.pending.delete(candidate.run.decls)
        spawn { unwind(candidate) }
      end
      @deferred.each do |object, staged|
        unless object.status.live?
          staged.discard
          next
        end
        object.deferred_runtime = false
        staged.activate
        @starts << Reload.task_starter(object)
      end
      host.install_tables(following, @tables, true)
      reason = ChordError.new(ErrorCode::Gone, "type no longer served")
      host.objects.values.each { |object| host.background(object.dispose(true, reason)) if @removed.includes?(object.type_name) }
      @removed.each { |name| host.host_objects.delete(name) }
      @facets.each { |facet| host.facets[facet.name] = facet }
      @options.remove.each { |name| host.facets.delete(name) }
      @facet_runs.each { |name, run| @starts << Reload.facet_switch(host, name, run) }
      @options.remove.each { |name| @starts << Reload.facet_switch(host, name, nil) }
      host.gating = nil
      @services.each do |name, service|
        pinned = host.host_objects[name]?
        if service.host_lifetime? && @changed.includes?(name) && !pinned.try(&.object).try(&.status.live?)
          @starts << Reload.host_object_starter(host, service)
        end
        if !service.host_lifetime? && pinned
          host.host_objects.delete(name)
          @starts << Reload.releaser(pinned)
        end
      end
      ReloadReport.new(following.id, previous.id, @changed.to_a, @removed.to_a, prepared, @gated.map(&.object.address))
    end

    private def install(candidate : Candidate, code_version : Int32) : Nil
      object = candidate.object
      run = candidate.run
      service = candidate.service
      object.pending.delete(run.decls)
      object.stop_tasks
      if candidate.gated?
        kept = run.decls.derives.values.to_set
        object.decls.derives.each_value { |derived| derived.detach unless kept.includes?(derived) }
      end
      object.decls = run.decls
      object.service = service
      run.decls.adopted.each_value(&.call)
      object.implementations[code_version] = Installed.new(code_version, service, run.implementation.not_nil!, run.decls)
      if candidate.gated?
        object.min_code_version = code_version
        object.implementations.keys.each { |old| @host.retire_implementation(object, old) unless old == code_version }
      end
      object.refresh_schemas
      run.decls.cells.each do |name, cell|
        schema = run.decls.cell_schemas[name]
        if candidate.migrated.has_key?(cell)
          cell.reset(candidate.migrated[cell], schema)
        else
          cell.schema = schema
        end
      end
      run.created_derives.each(&.attach(candidate.derived))
      candidate.staged.try(&.activate)
      @starts << Reload.task_starter(object)
      object.open_gate
      retoken(object, service)
      object.refs.to_a.each do |ref|
        if ref.owner.client? && !binds?(service, ref)
          object.release(ref)
          next
        end
        ref.shape_changed
      end
    end

    private def retoken(object : ObjectImpl, service : Service) : Nil
      pinned = @host.host_objects[object.type_name]?
      return unless pinned && pinned.object.same?(object) && pinned.contract.fingerprint != service.contract.fingerprint
      replacement = LocalRef.new(object, service.contract, RefOwner::Host)
      object.add_ref(replacement)
      @host.host_objects[object.type_name] = replacement
      pinned.release
    end

    private def binds?(service : Service, ref : LocalRef) : Bool
      Chord.bind(service.contract, service.accepts, ref.contract)
      true
    rescue error
      ref.gone(ChordError.new(ErrorCode::UpgradeRequired, "#{ref.object.type_name} changed; reload the web facets", cause: error))
      false
    end

    protected def self.task_starter(object : ObjectImpl) : Proc(Nil)
      -> { object.start_tasks }
    end

    protected def self.facet_switch(host : Host, name : String, run : AbortController?) : Proc(Nil)
      -> { host.facet_run_changed(name, run) }
    end

    protected def self.host_object_starter(host : Host, service : Service) : Proc(Nil)
      -> { host.start_host_object(service); nil }
    end

    protected def self.releaser(ref : Ref) : Proc(Nil)
      -> { ref.release }
    end
  end
end
