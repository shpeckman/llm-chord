# spec/reload_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private COUNT_V1 = T.object({n: T.number})

private GREETER = C.local("t.greeter",
  version: 1,
  input: T.object({id: T.optional(T.string(default: "a"))}),
  members: {greet: C.method(T.string, T.string), count: T.unknown})

private ITEM = C.local("t.item", version: 1, input: T.object({id: T.string}), members: {version: C.method(nil, T.string)})

private alias Bump = Proc(Delta::Draft, Nil)
private alias Extra = Proc(ObjectScope, JSON::Any, Nil)

private def n_bump : Bump
  ->(draft : Delta::Draft) { draft["n"] = (draft["n"]?.try(&.as_i) || 0_i64) + 1; nil }
end

private def greeter_facet(greeting : String, schema : TypeBox::Schema = COUNT_V1, initial = {n: 0}, bump : Bump = n_bump,
                          version : Int32 = 1, migrate = nil, extra : Extra? = nil) : Facet
  C.define_facet("greeter") do |api|
    api.serve(GREETER) do |input, _principal, scope|
      extra.try &.call(scope, input)
      count = scope.state("count", schema, initial, version: version, migrate: migrate)
      Implementation.new.state("count", count).method("greet") do |name, ctx|
        count.change(ctx) { |draft| bump.call(draft) }
        "#{greeting} #{name.not_nil!.as_s}"
      end
    end
  end
end

private def greet(ref : Ref, name : String, ctx : Ctx? = nil) : String
  ref.call("greet", name, ctx).not_nil!.as_s
end

private def chord_error(code : ErrorCode, &) : ChordError
  error = expect_raises(ChordError) { yield }
  error.code.should eq code
  error
end

private def upgrade_conflict?(& : -> _) : Bool
  yield
  false
rescue error : ChordError
  error.code.upgrade_conflict?
end

private class FailingSource
  include Subscribable

  def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
    raise "subscribe fails"
  end
end

private class Native
  property mutated = false
end

describe "reload" do
  it "compatible reload: no gate, pinned roots keep old code, state preserved, previous retires" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    ref = host.hold(GREETER)
    greet(ref, "a").should eq "hello a"
    go = Future(Nil).new
    pinned = Future(Array(String)).run do
      host.root do |ctx|
        first = greet(ref, "p", ctx)
        go.wait
        [first, greet(ref, "p", ctx)]
      end
    end
    tick
    shapes = [] of String
    ref.on_shape { |shape| shapes << shape.contract }
    report = host.reload([greeter_facet("hi")])
    report.gated.should be_empty
    report.prepared.size.should eq 1
    greet(ref, "b").should eq "hi b"
    shapes.size.should eq 1
    host.previous_code_version.should eq report.previous
    go.resolve(nil)
    pinned.wait.should eq ["hello p", "hello p"]
    host.previous_code_version.should be_nil
    ref.state("count").value.should eq j(%({"n":4}))
  end

  it "prepare runs in recording mode: writes throw and a failing factory leaves everything unchanged" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    a = host.hold(GREETER, {id: "a"})
    b = host.hold(GREETER, {id: "b"})
    a.ready.wait
    b.ready.wait
    captured = host.root { |ctx| ctx }
    writing = greeter_facet("hi", extra: ->(scope : ObjectScope, _input : JSON::Any) {
      scope.state("probe", T.object, {} of String => String).replace(captured, {} of String => String)
      nil
    })
    expect_raises(ChordError, /read_only/) { host.reload([writing]) }
    log = [] of String
    failing = greeter_facet("hi", extra: ->(scope : ObjectScope, input : JSON::Any) {
      id = input["id"].as_s
      scope.resource("extra", version: 1, close: ->(_value : Bool) { log << "close #{id}" }) { log << "open #{id}"; true }
      raise "b fails" if id == "b"
      nil
    })
    code_version = host.code_version
    error = chord_error(ErrorCode::Unavailable) { host.reload([failing]) }
    (error.message || "").should match(/reload aborted.*b fails/)
    host.code_version.should eq code_version
    log.should eq ["open a", "close a"]
    greet(a, "x").should eq "hello x"
  end

  it "refuses a changed cell schema without a version bump" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    host.hold(GREETER).ready.wait
    changed = greeter_facet("hi", schema: T.object({total: T.number}), initial: {total: 0})
    error = chord_error(ErrorCode::Invalid) { host.reload([changed]) }
    error.reason.should eq "state"
    (error.message || "").should match(/without a version bump/)
  end

  it "state bump: gate, migrate(old, from) into the new schema, reset to watchers, old roots upgrade_conflict" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    ref = host.hold(GREETER)
    greet(ref, "a")
    greet(ref, "a")
    events = [] of StateEvent
    ref.state("count").events { |event| events << event }
    go = Future(Nil).new
    late = Future(String).run { host.root { |ctx| go.wait; greet(ref, "late", ctx) } }
    froms = [] of Int32
    v2 = greeter_facet("hi", schema: T.object({total: T.number}), initial: {total: 0}, version: 2,
      bump: ->(draft : Delta::Draft) { draft["total"] = (draft["total"]?.try(&.as_i) || 0_i64) + 1; nil },
      migrate: ->(old : JSON::Any, from : Int32) { froms << from; {total: old["n"]} })
    report = host.reload([v2])
    report.gated.size.should eq 1
    froms.should eq [1]
    events.last.kind.should eq StateEvent::Kind::Reset
    events.last.value.should eq j(%({"total":2}))
    greet(ref, "b").should eq "hi b"
    ref.state("count").value.should eq j(%({"total":3}))
    go.resolve(nil)
    error = chord_error(ErrorCode::UpgradeConflict) { late.wait }
    error.retryable?.should be_true
  end

  it "versions are per cell: a raised one migrates only that cell, a lowered one is refused" do
    host = quiet_host
    pair = C.local("t.pair", version: 1, input: T.object, members: {a: T.unknown, b: T.unknown, bump: C.method})
    migrated = [] of String
    facet = ->(version : Int32) do
      C.define_facet("pair") do |api|
        api.serve(pair) do |_input, _principal, scope|
          a = scope.state("a", T.number, 1)
          b = scope.state("b", T.number, 1, version: version,
            migrate: ->(old : JSON::Any, from : Int32) { migrated << "b #{from}->#{version}"; old.as_i64 * 10 })
          Implementation.new.state("a", a).state("b", b).method("bump") { |_args, ctx| a.replace(ctx, a.value.as_i64 + 1) }
        end
      end
    end
    host.install(facet.call(1))
    ref = host.hold(pair)
    ref.ready.wait
    ref.call("bump")
    host.reload([facet.call(2)]).gated.size.should eq 1
    migrated.should eq ["b 1->2"]
    [ref.state("a").value, ref.state("b").value].should eq [JSON::Any.new(2_i64), JSON::Any.new(10_i64)]
    expect_raises(ChordError, /version of state b lowered from 2 to 1/) { host.reload([facet.call(1)]) }
  end

  it "gate: late old roots get upgrade_conflict, grandfathered roots re-enter, then commit" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    ref = host.hold(GREETER)
    ref.ready.wait
    go = Future(Nil).new
    grandfathered = Future(String).run do
      host.root do |ctx|
        greet(ref, "g", ctx)
        go.wait
        greet(ref, "g", ctx)
      end
    end
    tick
    reload = Future(ReloadReport).run { host.reload([greeter_facet("hi", version: 2)]) }
    eventually { upgrade_conflict? { greet(ref, "probe") } }
    go.resolve(nil)
    grandfathered.wait.should eq "hello g"
    reload.wait.gated.size.should eq 1
    greet(ref, "n").should eq "hi n"
  end

  it "gate deadline: reload aborts, reports blocking roots, nothing changes" do
    host = quiet_host
    log = [] of String
    facet = ->(greeting : String, version : Int32) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          scope.task do |ctx|
            log << "start #{greeting}"
            wait_abort(ctx.signal)
            log << "stop #{greeting}"
          end
          count = scope.state("count", T.number, 0, version: version)
          Implementation.new.state("count", count).method("greet") { |name| "#{greeting} #{name.not_nil!.as_s}" }
        end
      end
    end
    host.install(facet.call("hello", 1))
    ref = host.hold(GREETER)
    ref.ready.wait
    go = Future(Nil).new
    blocker = Future(Nil).run { host.root { |ctx| greet(ref, "b", ctx); go.wait } }
    tick
    error = chord_error(ErrorCode::Aborted) { host.reload([facet.call("hi", 2)], gate_deadline: 30.milliseconds) }
    error.reason.should eq "gate_deadline"
    (error.message || "").should match(/blocking roots: host#\w+:\d+/)
    greet(ref, "x").should eq "hello x"
    eventually { log.size == 3 }
    log.should eq ["start hello", "stop hello", "start hello"]
    go.resolve(nil)
    blocker.wait
  end

  it "exclusive resources are replaced at the gate; non-exclusive ones at prepare and closed at retirement" do
    host = quiet_host
    log = [] of String
    facet = ->(rev : Int32) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          lock = scope.resource("lock", version: rev, exclusive: true, close: ->(_value : Int32) { log << "close lock #{rev}" }) do
            log << "open lock #{rev}"
            rev
          end
          scope.resource("cache", version: rev, close: ->(_value : Bool) { log << "close cache #{rev}" }) do
            log << "open cache #{rev}"
            true
          end
          count = scope.state("count", T.number, 0)
          Implementation.new.state("count", count).method("greet") { |name| "#{lock.value} #{name.not_nil!.as_s}" }
        end
      end
    end
    host.install(facet.call(1))
    ref = host.hold(GREETER)
    greet(ref, "x").should eq "1 x"
    log.clear
    host.reload([facet.call(2)]).gated.size.should eq 1
    greet(ref, "x").should eq "2 x"
    eventually { log.size == 4 }
    log.should eq ["open cache 2", "close lock 1", "open lock 2", "close cache 1"]
  end

  it "two-version rule: the next reload retires the previous code version; its roots get superseded" do
    host = quiet_host
    host.install(greeter_facet("v1"))
    ref = host.hold(GREETER)
    ref.ready.wait
    first = host.code_version
    go = Future(Nil).new
    pinned = Future(String).run do
      host.root do |ctx|
        greet(ref, "p", ctx)
        go.wait
        greet(ref, "p", ctx)
      end
    end
    tick
    host.reload([greeter_facet("v2")])
    host.previous_code_version.should eq first
    host.reload([greeter_facet("v3")], retire_deadline: 20.milliseconds)
    go.resolve(nil)
    chord_error(ErrorCode::Superseded) { pinned.wait }.retryable?.should be_true
    chord_error(ErrorCode::Superseded) { host.root(code_version: first) { 1 } }
    greet(ref, "n").should eq "v3 n"
  end

  it "forced retirement aborts the leftover roots before it closes the resources only their code used" do
    host = quiet_host
    log = [] of String
    hold = Future(Nil).new
    facet = ->(version : Int32) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          conn = scope.resource("conn", version: version, close: ->(_value : Int32) { log << "close #{version}" }) { version }
          count = scope.state("count", COUNT_V1, {n: 0})
          Implementation.new.state("count", count).method("greet") do |name, ctx|
            case name.not_nil!.as_s
            when "hold"
              hold.wait
              "held on #{conn.value}, aborted #{ctx.signal.aborted?}"
            when "wait"
              wait_abort(ctx.signal)
              log << "aborted, conn #{conn.value}"
              "wait"
            else
              name.not_nil!.as_s
            end
          end
        end
      end
    end
    host.install(facet.call(1))
    ref = host.hold(GREETER)
    ref.ready.wait
    old = Future(String).run { host.root { |ctx| greet(ref, "wait", ctx) } }
    tick
    host.reload([facet.call(2)])
    current = Future(String).run { host.root { |ctx| greet(ref, "hold", ctx) } }
    tick
    host.reload([facet.call(3)], retire_deadline: 20.milliseconds)
    old.wait.should eq "wait"
    eventually { log.includes?("close 1") }
    log.should eq ["aborted, conn 1", "close 1"]
    hold.resolve(nil)
    current.wait.should eq "held on 2, aborted false"
    greet(ref, "x").should eq "x"
  end

  it "a kept resource closes with the newest declaration's close" do
    host = quiet_host
    log = [] of String
    facet = ->(label : String) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          scope.resource("conn", version: 1, close: ->(_value : Bool) { log << "close by #{label}" }) { true }
          count = scope.state("count", COUNT_V1, {n: 0})
          Implementation.new.state("count", count).method("greet") { |name| "#{label} #{name.not_nil!.as_s}" }
        end
      end
    end
    host.install(facet.call("a"))
    ref = host.hold(GREETER)
    ref.ready.wait
    host.reload([facet.call("b")])
    host.reload([facet.call("c")])
    greet(ref, "x").should eq "c x"
    log.should be_empty
    ref.release
    eventually { !log.empty? }
    log.should eq ["close by c"]
  end

  it "a task that ignores its abort delays its replacement at most task_stop_deadline (reported)" do
    errors = [] of Exception
    host = C.create_host(self: {kind: "host"}, on_error: ->(error : Exception) { errors << error }, task_stop_deadline: 50.milliseconds)
    log = [] of String
    stuck = Future(Nil).new
    facet = ->(label : String) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          scope.task do |_ctx|
            log << "start #{label}"
            stuck.wait if label == "a"
          end
          count = scope.state("count", COUNT_V1, {n: 0})
          Implementation.new.state("count", count).method("greet") { |name| name }
        end
      end
    end
    host.install(facet.call("a"))
    ref = host.hold(GREETER)
    ref.ready.wait
    host.reload([facet.call("b")])
    sleep 20.milliseconds
    log.should eq ["start a"]
    errors.should be_empty
    eventually { log.size == 2 }
    log.should eq ["start a", "start b"]
    errors.any? { |error| C.chord_error?(error, ErrorCode::Aborted) && (error.message || "").includes?("still running after 50 ms") }.should be_true
    stuck.resolve(nil)
  end

  it "a facet's signal aborts when its run is replaced or removed, when its reload aborts, and when the host closes" do
    host = quiet_host
    signals = {} of String => AbortSignal
    facet = ->(label : String, fail : Bool) do
      C.define_facet("greeter") do |api|
        signals[label] = api.signal
        api.serve(GREETER) do |_input, _principal, scope|
          raise "broken" if fail
          count = scope.state("count", COUNT_V1, {n: 0})
          Implementation.new.state("count", count).method("greet") { |name| name }
        end
      end
    end
    other = C.define_facet("other") { |api| signals["other"] = api.signal }
    host.install(facet.call("a", false))
    host.install(other)
    host.hold(GREETER).ready.wait
    expect_raises(ChordError) { host.reload([facet.call("b", true)]) }
    signals["b"].aborted?.should be_true
    signals["a"].aborted?.should be_false
    host.reload([facet.call("c", false)])
    signals["a"].aborted?.should be_true
    signals["c"].aborted?.should be_false
    host.reload(remove: ["other"])
    signals["other"].aborted?.should be_true
    host.close
    signals["c"].aborted?.should be_true
  end

  it "checks contracts at reload: forgotten bumps, live consumers, accepts adapters" do
    doc_v1 = C.remote("t.rdoc", version: 1, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(methods: {read: C.method(nil, T.object({text: T.string}))})})
    doc_broken = C.remote("t.rdoc", version: 1, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(methods: {read: C.method(nil, T.object({text: T.number}))})})
    doc_v2 = C.remote("t.rdoc", version: 2, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(methods: {fetch: C.method(nil, T.object({body: T.string}))})})
    host = quiet_host
    host.install(C.define_facet("doc") { |api| api.serve(doc_v1) { Implementation.new("main").method("read") { {text: "v1"} } } })
    consumer = host.hold(doc_v1)
    consumer.call("read").should eq j(%({"text":"v1"}))
    broken = C.define_facet("doc") { |api| api.serve(doc_broken) { Implementation.new("main").method("read") { {text: 1} } } }
    expect_raises(ChordError, /without a version bump/) { host.reload([broken]) }
    v2 = C.define_facet("doc") { |api| api.serve(doc_v2) { Implementation.new("main").method("fetch") { {body: "v2"} } } }
    chord_error(ErrorCode::ContractMismatch) { host.reload([v2]) }
    adapter = ->(current : Implementation) do
      fetch = current["fetch"].as(MethodFn)
      Implementation.new("main").method("read") { |_args, ctx| {text: "#{fetch.call(nil, ctx).not_nil!["body"]} via adapter"} }
    end
    adapted = C.define_facet("doc") do |api|
      api.serve(doc_v2, accepts: {1 => adapter}) { Implementation.new("main").method("fetch") { {body: "v2"} } }
    end
    host.reload([adapted])
    consumer.call("read").should eq j(%({"text":"v2 via adapter"}))
    host.hold(doc_v2).call("fetch").should eq j(%({"body":"v2"}))
  end

  it "rebinds listeners to the new code and restarts tasks" do
    host = quiet_host
    events = Emitter.new
    log = [] of String
    sum_type = C.local("t.sum", version: 1, input: T.object, members: {sum: T.object({v: T.number})})
    facet = ->(factor : Int32) do
      C.define_facet("sum") do |api|
        api.serve(sum_type) do |_input, _principal, scope|
          sum = scope.state("sum", T.object({v: T.number}), {v: 0})
          scope.on("add", events) do |value, ctx|
            sum.change(ctx) { |draft| draft["v"] = draft["v"].as_i + value.as_i64 * factor }
          end
          scope.task do |ctx|
            log << "start #{factor}"
            wait_abort(ctx.signal)
            log << "stop #{factor}"
          end
          Implementation.new.state("sum", sum)
        end
      end
    end
    host.install(facet.call(1))
    ref = host.hold(sum_type)
    ref.ready.wait
    events.emit(1)
    eventually { ref.state("sum").value == j(%({"v":1})) }
    host.reload([facet.call(10)])
    events.size.should eq 1
    events.emit(1)
    eventually { ref.state("sum").value == j(%({"v":11})) }
    eventually { log.size == 3 }
    log.should eq ["start 1", "stop 1", "start 10"]
  end

  it "keeps registry tables per code version" do
    host = quiet_host
    routes = C.define_registry(String, "t.reload-routes")
    router = C.local("t.router", version: 1, input: T.object)
    facet = ->(value : String) do
      C.define_facet("router") do |api|
        api.serve(router, lifetime: :host) do |_input, _principal, scope|
          scope.register(routes, {"GET /" => value})
          Implementation.new
        end
      end
    end
    host.install(facet.call("one"))
    seen = [] of Tuple(String?, Int32)
    host.registry(routes).subscribe { |table, code_version| seen << {table["GET /"]?, code_version} }
    go = Future(Nil).new
    pinned = Future(String?).run { host.root { |ctx| go.wait; host.registry(routes).get("GET /", ctx) } }
    tick
    report = host.reload([facet.call("two")])
    host.registry(routes).get("GET /").should eq "two"
    go.resolve(nil)
    pinned.wait.should eq "one"
    seen.should eq [{"one", report.previous}, {"two", report.code_version}]
  end

  it "a reload can add a type together with a consumer that holds it" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    ref = host.hold(GREETER)
    ref.ready.wait
    clock = C.local("t.clock", version: 1, input: T.object, members: {now: C.method(nil, T.number)})
    clock_facet = C.define_facet("clock") { |api| api.serve(clock) { Implementation.new.method("now") { 42 } } }
    consumer = ->(fail : Bool) do
      C.define_facet("greeter") do |api|
        api.serve(GREETER) do |_input, _principal, scope|
          held = scope.get(clock)
          count = scope.state("count", COUNT_V1, {n: 0})
          raise "consumer fails" if fail
          Implementation.new.state("count", count).method("greet") { |name, ctx| "#{held.call("now", ctx)} #{name.not_nil!.as_s}" }
        end
      end
    end
    code_version = host.code_version
    expect_raises(ChordError, /consumer fails/) { host.reload([clock_facet, consumer.call(true)]) }
    host.code_version.should eq code_version
    greet(ref, "x").should eq "hello x"
    host.reload([clock_facet, consumer.call(false)])
    greet(ref, "x").should eq "42 x"
  end

  it "the gate rejects new objects of a changed type; after commit they get the new code" do
    host = quiet_host
    host.install(greeter_facet("hello"))
    ref = host.hold(GREETER)
    ref.ready.wait
    go = Future(Nil).new
    grandfathered = Future(Nil).run { host.root { |ctx| greet(ref, "g", ctx); go.wait } }
    later = Future(Nil).new
    pinned = Future(String).run { host.root { |ctx| later.wait; greet(ref, "old", ctx) } }
    tick
    reload = Future(ReloadReport).run { host.reload([greeter_facet("hi", version: 2)]) }
    eventually { upgrade_conflict? { greet(ref, "probe") } }
    chord_error(ErrorCode::UpgradeConflict) { host.hold(GREETER, {id: "late"}) }.retryable?.should be_true
    go.resolve(nil)
    grandfathered.wait
    reload.wait
    greet(host.hold(GREETER, {id: "late"}), "l").should eq "hi l"
    host.previous_code_version.should_not be_nil
    later.resolve(nil)
    chord_error(ErrorCode::UpgradeConflict) { pinned.wait }
  end
end

describe "reload: commit" do
  it "a failing listener subscription fails prepare; the code version and all objects stay unchanged" do
    host = quiet_host
    sources = {"a" => Emitter.new.as(Subscribable), "b" => FailingSource.new.as(Subscribable), "c" => Emitter.new.as(Subscribable)}
    facet = ->(version : String, listen : Bool) do
      C.define_facet("item") do |api|
        api.serve(ITEM) do |input, _principal, scope|
          scope.on("events", sources[input["id"].as_s]) { } if listen
          Implementation.new.method("version") { version }
        end
      end
    end
    host.install(facet.call("v1", false))
    refs = %w[a b c].map { |id| host.hold(ITEM, {id: id}) }
    refs.each(&.ready.wait)
    code_version = host.code_version
    expect_raises(ChordError, /subscribe fails/) { host.reload([facet.call("v2", true)]) }
    host.code_version.should eq code_version
    refs.map(&.call("version")).should eq [JSON::Any.new("v1")] * 3
    sources["a"].as(Emitter).size.should eq 0
    sources["c"].as(Emitter).size.should eq 0
  end

  it "migration is validated against the new remote schemas, not the obsolete ones (dev mode)" do
    host = C.create_host(self: {kind: "host"}, dev: true, on_error: quiet_on_error)
    v1 = C.remote("t.counted", version: 1, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(state: {count: T.object({n: T.number})})})
    v2 = C.remote("t.counted", version: 2, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(state: {count: T.object({total: T.number})})})
    host.install(C.define_facet("counted") do |api|
      api.serve(v1, linger: 60.seconds) do |_input, _principal, scope|
        Implementation.new("main").state("count", scope.state("count", T.object({n: T.number}), {n: 3}))
      end
    end)
    first = host.hold(v1)
    first.ready.wait
    first.release
    host.reload([C.define_facet("counted") do |api|
      api.serve(v2, linger: 60.seconds) do |_input, _principal, scope|
        count = scope.state("count", T.object({total: T.number}), {total: 0}, version: 2,
          migrate: ->(old : JSON::Any, _from : Int32) { {total: old["n"]} })
        Implementation.new("main").state("count", count)
      end
    end])
    second = host.hold(v2)
    second.ready.wait
    second.state("count").value.should eq j(%({"total":3}))
  end

  it "reentrant observers calling another object during a commit see the whole new code version" do
    host = quiet_host
    other = C.local("t.other", version: 1, input: T.object, members: {version: C.method(nil, T.string)})
    facet = ->(version : String) do
      C.define_facet("pair") do |api|
        api.serve(ITEM) { Implementation.new.method("version") { version } }
        api.serve(other) { Implementation.new.method("version") { version } }
      end
    end
    host.install(facet.call("v1"))
    item = host.hold(ITEM, {id: "a"})
    peer = host.hold(other)
    item.ready.wait
    peer.ready.wait
    seen = [] of JSON::Any?
    item.on_shape { seen << peer.call("version") }
    host.reload([facet.call("v2")])
    seen.should eq [JSON::Any.new("v2")]
  end
end

describe "reload: leases and isolation" do
  store = C.local("t.store", version: 1, input: T.object, members: {count: T.unknown})

  it "a running listener holds a lease: the gate waits for it before migrating" do
    host = quiet_host
    events = Emitter.new
    go = Future(Nil).new
    seen = [] of JSON::Any
    host.install(C.define_facet("store") do |api|
      api.serve(store) do |_input, _principal, scope|
        count = scope.state("count", T.object({n: T.number}), {n: 1})
        scope.on("slow", events) { go.wait; seen << count.value }
        Implementation.new.state("count", count)
      end
    end)
    ref = host.hold(store)
    ref.ready.wait
    events.emit(1)
    tick
    code_version = host.code_version
    reload = Future(ReloadReport).run do
      host.reload([C.define_facet("store") do |api|
        api.serve(store) do |_input, _principal, scope|
          count = scope.state("count", T.object({total: T.number}), {total: 0}, version: 2,
            migrate: ->(old : JSON::Any, _from : Int32) { {total: old["n"]} })
          Implementation.new.state("count", count)
        end
      end], gate_deadline: 2.seconds)
    end
    sleep 20.milliseconds
    host.code_version.should eq code_version
    go.resolve(nil)
    reload.wait
    seen.should eq [j(%({"n":1}))]
    ref.state("count").value.should eq j(%({"total":1}))
  end

  it "a prepare rerun cannot touch retained resources, even open ones" do
    host = quiet_host
    db = C.local("t.db", version: 1, input: T.object, members: {read: C.method(nil, T.boolean)})
    native = Native.new
    facet = ->(touch : Bool) do
      C.define_facet("db") do |api|
        api.serve(db) do |_input, _principal, scope|
          resource = scope.resource("db", version: 1) { native }
          resource.value.mutated = true if touch
          Implementation.new.method("read") { resource.value.mutated }
        end
      end
    end
    host.install(facet.call(false))
    ref = host.hold(db)
    ref.ready.wait
    chord_error(ErrorCode::NotReady) { host.reload([facet.call(true)]) }
    native.mutated.should be_false
    ref.call("read").should eq JSON::Any.new(false)
  end

  it "objects of types a reload adds start listeners and tasks only at commit" do
    host = quiet_host
    log = [] of String
    fresh = C.local("t.fresh", version: 1, input: T.object)
    host.install(C.define_facet("item") { |api| api.serve(ITEM) { Implementation.new.method("version") { "v1" } } })
    %w[a b].each { |id| host.hold(ITEM, {id: id}).ready.wait }
    plugins = ->(fail : Bool) do
      [
        C.define_facet("fresh") do |api|
          api.serve(fresh) do |_input, _principal, scope|
            scope.task { log << "task started" }
            Implementation.new
          end
        end,
        C.define_facet("item") do |api|
          api.serve(ITEM) do |input, _principal, scope|
            scope.get(fresh)
            raise "b fails" if fail && input["id"].as_s == "b"
            Implementation.new.method("version") { "v2" }
          end
        end,
      ]
    end
    expect_raises(ChordError, /b fails/) { host.reload(plugins.call(true)) }
    sleep 10.milliseconds
    log.should be_empty
    host.reload(plugins.call(false))
    eventually { !log.empty? }
    log.should eq ["task started"]
  end

  it "a breaking provider change and its updated consumer reload in one batch" do
    host = quiet_host
    p1 = C.remote("t.provider", version: 1, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(methods: {get: C.method(nil, T.string)})})
    p2 = C.remote("t.provider", version: 2, input: T.object, host: C.host_named("host"),
      variants: {main: C.variant(methods: {fetch: C.method(nil, T.string)})})
    consumer_type = C.local("t.consumer", version: 1, input: T.object, members: {ask: C.method(nil, T.string)})
    host.install(C.define_facet("both") do |api|
      api.serve(p1) { Implementation.new("main").method("get") { "old" } }
      api.serve(consumer_type) do |_input, _principal, scope|
        provider = scope.get(p1)
        Implementation.new.method("ask") { |_args, ctx| provider.call("get", ctx) }
      end
    end)
    consumer = host.hold(consumer_type)
    consumer.call("ask").should eq JSON::Any.new("old")
    host.reload([C.define_facet("both") do |api|
      api.serve(p2) { Implementation.new("main").method("fetch") { "new" } }
      api.serve(consumer_type) do |_input, _principal, scope|
        provider = scope.get(p2)
        Implementation.new.method("ask") { |_args, ctx| provider.call("fetch", ctx) }
      end
    end])
    consumer.call("ask").should eq JSON::Any.new("new")
  end

  it "an exclusive resource whose close failed is restored on rollback, or marked unavailable" do
    db = C.local("t.db", version: 1, input: T.object, members: {read: C.method(nil, T.unknown)})
    %w[works fails].each do |reopen|
      host = quiet_host
      log = [] of String
      opens = 0
      facet = ->(rev : Int32) do
        C.define_facet("db") do |api|
          api.serve(db) do |_input, _principal, scope|
            port = scope.resource("port", version: rev, exclusive: true, close: ->(_value : Int32) {
              log << "close #{rev}"
              raise "close fails"
            }) do
              raise "new port fails" if rev == 2
              raise "reopen fails" if (opens += 1) > 1 && reopen == "fails"
              log << "open #{rev}"
              rev
            end
            Implementation.new.method("read") { {rev: port.value} }
          end
        end
      end
      host.install(facet.call(1))
      ref = host.hold(db)
      ref.ready.wait
      expect_raises(ChordError, /close fails/) { host.reload([facet.call(2)]) }
      if reopen == "works"
        log.should eq ["open 1", "close 1", "open 1"]
        ref.call("read").should eq j(%({"rev":1}))
      else
        chord_error(ErrorCode::Unavailable) { ref.call("read") }
      end
    end
  end

  it "retirement closes dropped resources before releasing dropped holds" do
    host = quiet_host
    log = [] of String
    dep = C.local("t.dep", version: 1, input: T.object)
    facet = ->(with_decls : Bool) do
      C.define_facet("item") do |api|
        api.serve(dep) do |_input, _principal, scope|
          scope.resource("r", version: 1, close: ->(_value : Bool) { log << "dep closed" }) { true }
          Implementation.new
        end
        api.serve(ITEM) do |_input, _principal, scope|
          if with_decls
            scope.get(dep)
            scope.resource("own", version: 1, close: ->(_value : Bool) { sleep 3.milliseconds; log << "own closed" }) { true }
          end
          Implementation.new.method("version") { with_decls ? "v1" : "v2" }
        end
      end
    end
    host.install(facet.call(true))
    ref = host.hold(ITEM, {id: "a"})
    ref.ready.wait
    go = Future(Nil).new
    pinned = Future(Nil).run { host.root { |ctx| ref.call("version", ctx); go.wait } }
    tick
    host.reload([facet.call(false)])
    log.should be_empty
    go.resolve(nil)
    pinned.wait
    eventually { log.size == 2 }
    log.should eq ["own closed", "dep closed"]
  end
end

private class Single
  getter subscribers = 0
  @emit : Proc(JSON::Any, Nil)? = nil

  def start(listener : Proc(JSON::Any, Nil)) : Proc(Nil)
    raise "Watch is already started" if @subscribers > 0
    @subscribers += 1
    @emit = listener
    -> { @subscribers -= 1; nil }
  end

  def emit(event : String) : Nil
    @emit.try &.call(JSON::Any.new(event))
  end
end

private class SingleAdapter
  include Subscribable

  def initialize(@single : Single); end

  def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
    @single.start(listener)
  end
end

private class CountingSource
  include Subscribable
  getter subscribes = 0

  def subscribe(&listener : JSON::Any -> Nil) : Proc(Nil)
    @subscribes += 1
    -> { }
  end
end

describe "reload: facets, listeners and derivations" do
  it "facets reach their own host through FacetApi.root and FacetApi.registry" do
    config = C.define_registry(String, "t.config")
    settings = C.local("t.settings", version: 1, input: T.object)
    reader = C.local("t.reader", version: 1, input: T.object, members: {read: C.method(nil, T.string)})
    captured = [] of FacetApi
    facet = ->(value : String) do
      C.define_facet("config") do |api|
        captured << api
        api.serve(settings, lifetime: :host) do |_input, _principal, scope|
          scope.register(config, {"greeting" => value})
          Implementation.new
        end
        api.serve(reader) { Implementation.new.method("read") { |_args, ctx| api.registry(config).get("greeting", ctx) || "" } }
      end
    end
    host = C.create_host(self: {kind: "host"}, name: "worker", on_error: quiet_on_error)
    host.install(facet.call("v1"))
    api = captured[0]
    api.name.should eq "worker"
    api.root { |ctx| ctx.get(reader).call("read", ctx) }.should eq JSON::Any.new("v1")
    host.reload([facet.call("v2")])
    captured[1].registry(config).get("greeting").should eq "v2"
    api.root { |ctx| ctx.get(reader).call("read", ctx) }.should eq JSON::Any.new("v2")
  end

  it "a listener keeps its subscription across reloads when resource and select are unchanged" do
    watcher = C.local("t.watcher", version: 1, input: T.object, members: {seen: T.array(T.string)})
    single = Single.new
    facet = ->(tag : String) do
      C.define_facet("watcher") do |api|
        api.serve(watcher) do |_input, _principal, scope|
          seen = scope.state("seen", T.array(T.string), [] of String)
          watch = scope.resource("watch", version: 1) { single }
          scope.on("events", watch, ->(source : Single) { SingleAdapter.new(source) }) do |event, ctx|
            seen.change(ctx) { |draft| draft << "#{tag}:#{event.as_s}" }
          end
          Implementation.new.state("seen", seen)
        end
      end
    end
    host = quiet_host
    host.install(facet.call("v1"))
    ref = host.hold(watcher)
    ref.ready.wait
    single.emit("a")
    host.reload([facet.call("v2")])
    host.reload([facet.call("v3")])
    single.emit("b")
    eventually { ref.state("seen").value.as_a.size == 2 }
    single.subscribers.should eq 1
    ref.state("seen").value.should eq j(%(["v1:a","v3:b"]))
  end

  it "a changed select resubscribes" do
    watcher = C.local("t.watcher2", version: 1, input: T.object)
    source = CountingSource.new
    facet = ->(select_text : Bool) do
      C.define_facet("watcher2") do |api|
        api.serve(watcher) do |_input, _principal, scope|
          resource = scope.resource("s", version: 1) { source }
          selector = select_text ? ->(s : CountingSource) { s } : ->(value : CountingSource) { value }
          scope.on("s", resource, selector) { }
          Implementation.new
        end
      end
    end
    host = quiet_host
    host.install(facet.call(true))
    host.hold(watcher).ready.wait
    host.reload([facet.call(true)])
    source.subscribes.should eq 1
    host.reload([facet.call(false)])
    source.subscribes.should eq 2
  end

  it "a listener on state gets the current value at start and again after a reload replaced its derivation" do
    host = quiet_host
    doubled = C.local("t.doubled", version: 1, input: T.object, members: {set: C.method(T.number)})
    seen = [] of Int64
    facet = ->(label : String) do
      C.define_facet("doubled") do |api|
        api.serve(doubled, lifetime: :host) do |_input, _principal, scope|
          n = scope.state("n", T.number, 1)
          twice = scope.derive([n]) { |(value)| value.as_i64 * 2 }
          scope.on("doubled", twice) { |value| seen << value.as_i64; label }
          Implementation.new.method("set") { |value, ctx| n.replace(ctx, value.not_nil!) }
        end
      end
    end
    host.install(facet.call("v1"))
    eventually { seen.size == 1 }
    host.root { |ctx| host.hold(doubled).call("set", 5, ctx) }
    eventually { seen.size == 2 }
    seen.should eq [2, 10]
    host.reload([facet.call("v2")])
    eventually { seen.size == 3 }
    tick
    seen.should eq [2, 10, 10]
  end
end

describe "reload across a link" do
  doc = C.remote("t.e8-doc", version: 1, input: T.object, host: C.host_named("server"), variants: {
    a: C.variant(state: {x: T.number}, methods: {bump: C.method}),
    b: C.variant(state: {x: T.number, y: T.string}, methods: {bump: C.method}),
    c: C.variant(state: {y: T.string}, methods: {bump: C.method}),
  })

  it "a new variant's members arrive with its shape; a member outside the variant throws not_in_variant" do
    doc_facet = ->(variant : String) do
      C.define_facet("doc") do |api|
        api.serve(doc) do |_input, _principal, scope|
          x = scope.state("x", T.number, 1)
          y = scope.state("y", T.string, "why")
          implementation = Implementation.new(variant).method("bump") { |_args, ctx| x.replace(ctx, x.value.as_i64 + 1) }
          implementation.state("x", x) unless variant == "c"
          implementation.state("y", y) unless variant == "a"
          implementation
        end
      end
    end
    server = C.create_host(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    down, up = C.memory_link_pair
    server.accept(down, principal: {user: "u"})
    link = CountingLink.new(up)
    browser = C.create_host(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(link, principal: {kind: "server"}))
    server.install(doc_facet.call("a"))
    ref = browser.hold(doc)
    ref.ready.wait
    ref.variant.should eq "a"
    ref.state("x").value.should eq JSON::Any.new(1_i64)
    chord_error(ErrorCode::NotInVariant) { ref.state("y").value }
    failures = [] of Exception
    ref.on_shape do |shape|
      %w[x y].each do |name|
        member = doc.description.variants[shape.variant || ""]?.try(&.[name]?)
        next unless member.try(&.state?)
        begin
          ref.state(name).value
        rescue error
          failures << error
        end
      end
    end
    before = state_frames(link.received).size
    server.reload([doc_facet.call("b")])
    eventually { ref.variant == "b" }
    ref.state("y").value.should eq JSON::Any.new("why")
    ref.state("x").value.should eq JSON::Any.new(1_i64)
    unit = state_frames(link.received)[before..]
    unit.select { |frame| frame.string("as") == "snap" }.map(&.string("m")).should eq ["y"]
    server.reload([doc_facet.call("c")])
    eventually { ref.variant == "c" }
    chord_error(ErrorCode::NotInVariant) { ref.state("x").value }
    ref.state("y").value.should eq JSON::Any.new("why")
    failures.should be_empty
    browser.close
    server.close
  end
end
