# spec/host_objects_reload_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private FLAGS = T.record(T.string, T.boolean)

private SWITCH_V1 = C.local("t.eager-switch", version: 1, input: T.object,
  members: {enabled: T.boolean, set: C.method(T.boolean)})
private SWITCH_V2 = C.local("t.eager-switch", version: 2, input: T.object,
  members: {enabled: FLAGS, set: C.method(T.object({conversation: T.number, enabled: T.boolean}))})
private SWITCH_V3 = C.local("t.eager-switch", version: 3, input: T.object,
  members: {enabled: FLAGS, update: C.method(T.object({conversation: T.number, enabled: T.boolean}))})

private READ = C.define_registry(Proc(JSON::Any), "t.eager-switch-read")

private READ_V1 = C.local("t.eager-read", version: 1, input: T.object, members: {read: C.method(nil, T.string)})
private READ_V2 = C.local("t.eager-read", version: 2, input: T.object, members: {fetch: C.method(nil, T.string)})

private def watch(scope : ObjectScope, log : Array(String)) : Nil
  scope.resource("watch", version: 1, close: ->(_value : Bool) { log << "close" }) { log << "open"; true }
end

private def reader(cell : Cell) : Proc(JSON::Any)
  -> { cell.value }
end

private def switch_v1(log : Array(String)) : Facet
  C.define_facet("switch") do |api|
    api.serve(SWITCH_V1, lifetime: :host) do |_input, _principal, scope|
      watch(scope, log)
      enabled = scope.state("enabled", T.boolean, false)
      scope.register(READ, {"current" => reader(enabled)})
      Implementation.new.state("enabled", enabled).method("set") { |value, ctx| enabled.replace(ctx, value.not_nil!) }
    end
  end
end

private def switch_v2(log : Array(String), valid : Bool) : Facet
  C.define_facet("switch") do |api|
    api.serve(SWITCH_V2, lifetime: :host) do |_input, _principal, scope|
      watch(scope, log)
      enabled = scope.state("enabled", FLAGS, {} of String => Bool, version: 2, migrate: ->(old : JSON::Any, from : Int32) {
        raise "from #{from}" unless from == 1
        valid ? {"1" => old} : JSON::Any.new("invalid migration")
      })
      scope.register(READ, {"current" => reader(enabled)})
      Implementation.new.state("enabled", enabled).method("set") do |args, ctx|
        enabled.change(ctx) { |draft| draft[args.not_nil!["conversation"].as_i64.to_s] = args.not_nil!["enabled"] }
      end
    end
  end
end

private def switch_v3(log : Array(String)) : Facet
  C.define_facet("switch") do |api|
    api.serve(SWITCH_V3, lifetime: :host) do |_input, _principal, scope|
      watch(scope, log)
      enabled = scope.state("enabled", FLAGS, {} of String => Bool, version: 2)
      scope.register(READ, {"current" => reader(enabled)})
      Implementation.new.state("enabled", enabled).method("update") do |args, ctx|
        enabled.change(ctx) { |draft| draft[args.not_nil!["conversation"].as_i64.to_s] = args.not_nil!["enabled"] }
      end
    end
  end
end

private def reader_v1 : Facet
  C.define_facet("read") { |api| api.serve(READ_V1, lifetime: :host) { Implementation.new.method("read") { "one" } } }
end

private def reader_v2(adapt : Bool = false) : Facet
  adapter = ->(current : Implementation) { Implementation.new.tap { |view| view["read"] = current["fetch"] } }
  accepts = adapt ? {1 => adapter} : nil
  C.define_facet("read") do |api|
    api.serve(READ_V2, lifetime: :host, accepts: accepts) { Implementation.new.method("fetch") { "two" } }
  end
end

private def current_flags(host : Host) : JSON::Any
  host.registry(READ).get("current").not_nil!.call
end

describe "host objects across reloads" do
  it "the host's reference follows contract bumps at commit without reopening its object or resources; failures keep the old one" do
    errors = [] of Exception
    host = C.create_host(self: {kind: "host"}, dev: true, on_error: ->(error : Exception) { errors << error })
    log = [] of String
    host.load([switch_v1(log)])
    original = host.hold(SWITCH_V1)
    original.call("set", true)
    original.release
    code_version = host.code_version
    expect_raises(ChordError) { host.reload([switch_v2(log, false)]) }.code.should eq ErrorCode::Invalid
    host.code_version.should eq code_version
    current_flags(host).should eq JSON::Any.new(true)
    report = host.reload([switch_v2(log, true)])
    report.gated.size.should eq 1
    current_flags(host).should eq j(%({"1":true}))
    modern = host.hold(SWITCH_V2)
    modern.call("set", {conversation: 2, enabled: true})
    modern.release
    host.reload([switch_v3(log)]).gated.should be_empty
    current_flags(host).should eq j(%({"1":true,"2":true}))
    host.ready
    log.should eq ["open"]
    errors.should be_empty
    host.close
    log.should eq ["open", "close"]
  end

  it "external old-version consumers still refuse an upgrade without accepts, and keep their adapter when it is provided" do
    errors = [] of Exception
    host = C.create_host(self: {kind: "host"}, on_error: ->(error : Exception) { errors << error })
    host.load([reader_v1])
    consumer = host.hold(READ_V1)
    consumer.call("read").should eq JSON::Any.new("one")
    expect_raises(ChordError) { host.reload([reader_v2]) }.code.should eq ErrorCode::ContractMismatch
    consumer.call("read").should eq JSON::Any.new("one")
    host.reload([reader_v2(true)])
    consumer.call("read").should eq JSON::Any.new("two")
    consumer.contract.should be READ_V1
    host.hold(READ_V2).call("fetch").should eq JSON::Any.new("two")
    errors.should be_empty
    host.close
  end

  it "object-owned old-version references still block an upgrade unless their consumer is replaced in the same batch" do
    host = quiet_host
    consumer_type = C.local("t.eager-consumer", version: 1, input: T.object, members: {read: C.method(nil, T.string)})
    old_consumer = C.define_facet("consumer") do |api|
      api.serve(consumer_type) do |_input, _principal, scope|
        held = scope.get(READ_V1)
        Implementation.new.method("read") { |_args, ctx| held.call("read", ctx) }
      end
    end
    new_consumer = C.define_facet("consumer") do |api|
      api.serve(consumer_type) do |_input, _principal, scope|
        held = scope.get(READ_V2)
        Implementation.new.method("read") { |_args, ctx| held.call("fetch", ctx) }
      end
    end
    host.load([reader_v1, old_consumer])
    consumer = host.hold(consumer_type)
    consumer.call("read").should eq JSON::Any.new("one")
    expect_raises(ChordError) { host.reload([reader_v2]) }.code.should eq ErrorCode::ContractMismatch
    consumer.call("read").should eq JSON::Any.new("one")
    host.reload([reader_v2, new_consumer])
    consumer.call("read").should eq JSON::Any.new("two")
    host.close
  end

  it "a forgotten contract bump remains refused even when the only consumer is the host's own reference" do
    host = quiet_host
    host.load([reader_v1])
    incompatible = C.local(READ_V1.name, version: 1, input: T.object, members: {fetch: C.method(nil, T.string)})
    error = expect_raises(ChordError) do
      host.reload([C.define_facet("read") { |api| api.serve(incompatible, lifetime: :host) { Implementation.new.method("fetch") { "bad" } } }])
    end
    error.code.should eq ErrorCode::ContractMismatch
    (error.message || "").should match(/without a version bump/)
    host.hold(READ_V1).call("read").should eq JSON::Any.new("one")
    host.close
  end

  it "a cluster contract upgrade retokens the server's and worker's references only after unanimous preparation" do
    log = [] of String
    valid = false
    server = C.create_host(self: {kind: "host"}, on_error: quiet_on_error)
    worker = C.create_host(self: {kind: "host"}, name: "worker", on_error: quiet_on_error,
      loader: ->(_names : Array(String)) { [switch_v2(log, valid)] })
    server.load([switch_v1(log)])
    worker.load([switch_v1(log)])
    down, up = C.memory_link_pair
    server.accept(down, kind: :host, name: "worker", principal: {worker: true})
    worker.connect(up, principal: {kind: "server"})
    tick
    expect_raises(ChordError) { server.reload([switch_v2(log, true)], remote: {"worker" => ["switch"]}) }.code.should eq ErrorCode::Invalid
    current_flags(server).should eq JSON::Any.new(false)
    current_flags(worker).should eq JSON::Any.new(false)
    valid = true
    server.reload([switch_v2(log, true)], remote: {"worker" => ["switch"]})
    tick
    current_flags(server).should eq j(%({"1":false}))
    eventually { current_flags(worker) == j(%({"1":false})) }
    server.code_version.should eq worker.code_version
    log.should eq ["open", "open"]
    worker.close
    server.close
  end

  it "a reload that changes a type's lifetime creates its host object, or lets it go" do
    host = quiet_host
    kept = C.local("t.lifetime-change", version: 1, input: T.object)
    log = [] of String
    facet = ->(lifetime : Lifetime) do
      C.define_facet("kept") do |api|
        api.serve(kept, lifetime: lifetime) do |_input, _principal, scope|
          scope.resource("life", version: 1, close: ->(_value : Bool) { log << "close" }) { log << "open #{lifetime.to_s.downcase}"; true }
          Implementation.new
        end
      end
    end
    host.install(facet.call(Lifetime::Referenced))
    log.should be_empty
    host.reload([facet.call(Lifetime::Host)])
    host.ready
    log.should eq ["open host"]
    host.reload([facet.call(Lifetime::Referenced)])
    eventually { log.size == 2 }
    log.should eq ["open host", "close"]
    host.close
  end
end
