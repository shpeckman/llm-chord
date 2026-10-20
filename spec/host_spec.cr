# spec/host_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private COUNTER = C.local("t.counter",
  version: 1,
  input: T.object({name: T.string}),
  members: {count: T.object({n: T.number}), add: C.method(T.number, T.number)})

private VIEW = T.object({text: T.string})

private DOC = C.remote("t.doc",
  version: 1,
  input: T.object({id: T.string}),
  host: C.host_named("host"),
  variants: {
    viewer: C.variant(state: {view: VIEW}),
    editor: C.variant(state: {view: VIEW}, methods: {edit: C.method(T.object({text: T.string}), T.object({ok: T.boolean}))}),
  })

private STORE = C.local("t.store",
  version: 1,
  input: T.object({scope: T.optional(T.string(default: "all"))}),
  members: {seen: C.opaque("t.seen@1")})

private SOURCE = C.local("t.source", version: 1, input: T.object, members: {n: T.number, set: C.method(T.number)})

private def serve_counter(host : Host, log : Array(String), linger : Time::Span? = nil) : Nil
  host.serve(COUNTER, linger: linger) do |input, _principal, scope|
    name = input["name"].as_s
    log << "factory #{name}"
    count = scope.state("count", T.object({n: T.number}), {n: 0})
    scope.resource("conn", version: 1, close: ->(_conn : String) { log << "close #{name}" }) do
      log << "open #{name}"
      name
    end
    Implementation.new.state("count", count).method("add") do |delta, ctx|
      count.change(ctx) { |draft| draft["n"] = draft["n"].as_i + delta.not_nil!.as_i }
      count.value["n"]
    end
  end
end

private def serve_doc(host : Host, principals : Array(JSON::Any) = [] of JSON::Any) : Nil
  host.serve(DOC) do |_input, principal, scope|
    principals << principal
    view = scope.state("view", VIEW, {text: ""})
    next Implementation.new("viewer").state("view", view) unless principal["role"]?.try(&.as_s?) == "editor"
    Implementation.new("editor").state("view", view).method("edit") do |args, ctx|
      text = args.not_nil!["text"].as_s
      view.replace(ctx, {text: text})
      text == "bad" ? {ok: "no"} : {ok: true}
    end
  end
end

private def serve_source(host : Host) : Nil
  host.serve(SOURCE) do |_input, _principal, scope|
    n = scope.state("n", T.number, 1)
    Implementation.new.state("n", n).method("set") { |value, ctx| n.replace(ctx, value.not_nil!) }
  end
end

private def chord_error(code : ErrorCode, &) : ChordError
  error = expect_raises(ChordError) { yield }
  error.code.should eq code
  error
end

private def empty_contract(name : String) : LocalContract
  C.local(name, version: 1, input: T.object)
end

describe "host: activation and lifetime" do
  it "activates, goes live, binds members late, disposes after release" do
    host = quiet_host
    log = [] of String
    serve_counter(host, log)
    ref = host.hold(COUNTER, {name: "a"})
    ref.status.should eq RefStatus::Loading
    chord_error(ErrorCode::NotReady) { ref.state("count").value }
    pending = Future(JSON::Any?).run { ref.call("add", 2) }
    ref.ready.wait
    ref.status.should eq RefStatus::Live
    pending.wait.should eq JSON::Any.new(2_i64)
    ref.state("count").value.should eq j(%({"n":2}))
    ref.release
    ref.status.should eq RefStatus::Released
    chord_error(ErrorCode::Released) { ref.call("add", 1) }
    eventually { log.size == 3 }
    log.should eq ["factory a", "open a", "close a"]
  end

  it "coalesces concurrent gets and keeps the object while held" do
    host = quiet_host
    log = [] of String
    serve_counter(host, log)
    a = host.hold(COUNTER, {name: "x"})
    b = host.hold(COUNTER, {name: "x"})
    a.ready.wait
    b.ready.wait
    log.should eq ["factory x", "open x"]
    a.release
    tick
    b.call("add", 1).should eq JSON::Any.new(1_i64)
    b.release
    eventually { log.size == 3 }
    log.should eq ["factory x", "open x", "close x"]
  end

  it "lingers after the last release and revives on a new get" do
    host = quiet_host
    log = [] of String
    serve_counter(host, log, 30.milliseconds)
    a = host.hold(COUNTER, {name: "l"})
    a.call("add", 5)
    a.release
    b = host.hold(COUNTER, {name: "l"})
    b.ready.wait
    b.state("count").value.should eq j(%({"n":5}))
    b.release
    sleep 60.milliseconds
    log.should eq ["factory l", "open l", "close l"]
  end

  it "disposes an abandoned activation once it settles" do
    host = quiet_host
    log = [] of String
    proceed = Channel(Nil).new(1)
    slow = empty_contract("t.slow")
    host.serve(slow) do |_input, _principal, scope|
      scope.resource("r", version: 1, close: ->(_r : String) { log << "closed" }) do |signal|
        signal.on_abort { log << "abort seen" }
        proceed.receive
        "r"
      end
      Implementation.new
    end
    ref = host.hold(slow)
    tick
    ref.release
    tick
    proceed.send(nil)
    eventually { log.size == 2 }
    log.should eq ["abort seen", "closed"]
    again = host.hold(slow)
    tick
    proceed.send(nil)
    again.ready.wait
    again.status.should eq RefStatus::Live
  end

  it "propagates activation failures to dependents and retries on the next get" do
    host = quiet_host
    fail = true
    leaf = empty_contract("t.leaf")
    parent = empty_contract("t.parent")
    host.serve(leaf) do |_input, _principal, scope|
      scope.resource("r", version: 1) do
        raise "boom" if fail
        1
      end
      Implementation.new
    end
    host.serve(parent) do |_input, _principal, scope|
      scope.get(leaf)
      Implementation.new
    end
    held = host.hold(parent)
    error = chord_error(ErrorCode::Unavailable) { held.ready.wait }
    error.message.not_nil!.should contain "boom"
    held.status.should eq RefStatus::Gone
    fail = false
    retry = host.hold(parent)
    retry.ready.wait
    retry.status.should eq RefStatus::Live
  end

  it "unwinds declarations when a factory throws" do
    host = quiet_host
    leaf = empty_contract("t.leaf2")
    bad = empty_contract("t.bad")
    leaf_live = 0
    host.serve(leaf) do |_input, _principal, scope|
      scope.resource("r", version: 1, close: ->(_value : Int32) { leaf_live -= 1 }) { leaf_live += 1 }
      Implementation.new
    end
    host.serve(bad) do |_input, _principal, scope|
      scope.get(leaf)
      raise "factory failed"
    end
    expect_raises(ChordError, /factory failed/) { host.hold(bad).ready.wait }
    eventually { leaf_live == 0 }
  end

  it "rejects duplicate declaration names" do
    host = quiet_host
    dup = empty_contract("t.dup")
    host.serve(dup) do |_input, _principal, scope|
      scope.state("a", T.object, {} of String => JSON::Any)
      scope.state("a", T.object, {} of String => JSON::Any)
      Implementation.new
    end
    expect_raises(ChordError, /duplicate state name a/) { host.hold(dup).ready.wait }
  end

  it "detects hold cycles" do
    host = quiet_host
    a = empty_contract("t.cycle-a")
    b = empty_contract("t.cycle-b")
    host.serve(a) { |_input, _principal, scope| scope.get(b); Implementation.new }
    host.serve(b) { |_input, _principal, scope| scope.get(a); Implementation.new }
    expect_raises(ChordError, /cycle/) { host.hold(a).ready.wait }
  end

  it "closes resources in reverse order, runs all steps and aggregates errors" do
    errors = [] of Exception
    host = quiet_host(errors)
    log = [] of String
    multi = empty_contract("t.multi")
    host.serve(multi) do |_input, _principal, scope|
      a = scope.resource("a", version: 1, close: ->(_value : String) { log << "close a" }) { "a" }
      scope.resource("b", version: 1, deps: [a], close: ->(_value : String) { log << "close b"; raise "b failed" }) { "b" }
      scope.resource("c", version: 1, close: ->(_value : String) { log << "close c"; raise "c failed" }) { "c" }
      Implementation.new
    end
    ref = host.hold(multi)
    ref.ready.wait
    ref.release
    eventually { errors.size == 1 }
    log.last.should eq "close a"
    log.size.should eq 3
    errors[0].as(AggregateError).errors.size.should eq 2
  end

  it "releases ctx.get holds when the call settles" do
    host = quiet_host
    log = [] of String
    serve_counter(host, log)
    value = host.root do |ctx|
      counter = ctx.get(COUNTER, {name: "c"})
      counter.call("add", 3, ctx)
    end
    value.should eq JSON::Any.new(3_i64)
    eventually { log.size == 3 }
    log.should eq ["factory c", "open c", "close c"]
  end
end

describe "host: declarations and methods" do
  it "refuses a second declaration of one name per kind; kinds have their own names" do
    host = quiet_host
    twice = C.local("t.twice", version: 1, input: T.object({kind: T.string}))
    host.serve(twice) do |input, _principal, scope|
      kind = input["kind"].as_s
      scope.state("x", T.number, 0)
      scope.resource("x", version: 1) { nil }
      scope.on("x", scope.state("y", T.number, 0)) { }
      scope.state("x", T.number, 1) if kind == "state"
      scope.resource("x", version: 1) { nil } if kind == "resource"
      scope.on("x", scope.state("z", T.number, 0)) { } if kind == "listener"
      Implementation.new
    end
    host.hold(twice, {kind: "none"}).ready.wait
    %w[state resource listener].each do |kind|
      error = chord_error(ErrorCode::Invalid) { host.hold(twice, {kind: kind}).ready.wait }
      error.reason.should eq "duplicate"
      error.message.not_nil!.should contain "#{kind} name x"
    end
  end

  it "methods without arguments are called with ctx alone; void methods resolve to nil" do
    host = quiet_host
    tool = C.local("t.tool", version: 1, input: T.object, members: {
      ping:  C.method,
      count: C.method(nil, T.number),
      note:  C.method(T.string),
    })
    seen = [] of String
    host.serve(tool) do
      Implementation.new
        .method("ping") { |args, ctx| seen << "ctx #{args.nil?} #{!ctx.root_id.empty?}"; "ignored" }
        .method("count") { 3 }
        .method("note") { |text, ctx| seen << text.not_nil!.as_s << "ctx #{!ctx.root_id.empty?}" }
    end
    ref = host.hold(tool)
    ref.ready.wait
    ref.call("ping", "dropped").should be_nil
    host.root { |ctx| ref.call("count", ctx) }.should eq JSON::Any.new(3_i64)
    ref.call("note", "hi").should be_nil
    seen.should eq ["ctx true true", "hi", "ctx true"]
  end
end

describe "host: lifetime" do
  it %(serve refuses a lifetime "host" the type cannot have) do
    host = quiet_host
    remote = C.remote("t.remote-store", version: 1, input: T.object, host: C.host_named("host"), variants: {main: C.variant})
    keyed = C.local("t.keyed", version: 1, input: T.object({id: T.string}))
    expect_raises(ArgumentError, /needs a local type/) { host.serve(remote, lifetime: :host) { Implementation.new("main") } }
    expect_raises(ArgumentError, /input that accepts \{\}/) { host.serve(keyed, lifetime: :host) { Implementation.new } }
    expect_raises(ArgumentError, /does not linger/) do
      host.serve(STORE, lifetime: :host, linger: 10.milliseconds) { Implementation.new.opaque("seen", nil) }
    end
    optional = C.local("t.optional", version: 1, input: T.object({id: T.optional(T.string)}))
    host.serve(optional, lifetime: :host) { Implementation.new }
    host.serve(keyed, linger: 10.milliseconds) { Implementation.new }
    host.serve(remote, linger: 10.milliseconds) { Implementation.new("main") }
  end

  it "every get reaches the one object, created at serve for the host principal; another input is invalid" do
    host = C.create_host(self: {kind: "host"}, principal_key: ->(principal : JSON::Any) { principal.to_json },
      on_error: ->(_error : Exception) { })
    created = [] of JSON::Any
    host.serve(STORE, lifetime: :host) do |_input, principal|
      created << principal
      Implementation.new.opaque("seen", principal)
    end
    host.ready
    created.size.should eq 1
    guest = host.hold(STORE, nil, principal: {guest: "g"})
    defaults = host.hold(STORE, {scope: "all"})
    guest.ready.wait
    defaults.ready.wait
    created.size.should eq 1
    guest.opaque("seen", JSON::Any).should eq created[0]
    chord_error(ErrorCode::Invalid) { host.hold(STORE, {scope: "other"}) }
    guest.release
    defaults.release
    tick
    again = host.hold(STORE)
    again.ready.wait
    created.size.should eq 1
    host.close
    again.status.should eq RefStatus::Gone
  end
end

describe "host: principals, variants and disposal" do
  it "keeps objects per principal key and enforces variants" do
    host = C.create_host(self: {kind: "host"}, on_error: ->(_error : Exception) { },
      principal_key: ->(principal : JSON::Any) { principal["user"]?.try(&.as_s?) || "" })
    principals = [] of JSON::Any
    serve_doc(host, principals)
    viewer = host.hold(DOC, {id: "1"}, principal: {user: "v", role: "viewer"})
    editor = host.hold(DOC, {id: "1"}, principal: {user: "e", role: "editor"})
    viewer.ready.wait
    editor.ready.wait
    principals.size.should eq 2
    viewer.variant.should eq "viewer"
    viewer.shape.not_nil!.members.should eq ["view"]
    chord_error(ErrorCode::NotInVariant) { viewer.call("edit", {text: "x"}) }
    editor.variant.should eq "editor"
    editor.call("edit", {text: "x"}).should eq j(%({"ok":true}))
    editor.state("view").value.should eq j(%({"text":"x"}))
    viewer.state("view").value.should eq j(%({"text":""}))
  end

  it "validates remote args and results at the provider boundary" do
    host = quiet_host
    serve_doc(host)
    editor = host.get(DOC, {id: "2"}, principal: {role: "editor"})
    editor.variant.should eq "editor"
    chord_error(ErrorCode::Invalid) { editor.call("edit", {text: 1}) }.reason.should eq "args"
    chord_error(ErrorCode::Invalid) { editor.call("edit", {text: "bad"}) }.reason.should eq "result"
  end

  it "forced disposal makes references gone and aborts in-flight calls" do
    host = quiet_host
    seen_abort = false
    slow = C.local("t.inflight", version: 1, input: T.object, members: {wait: C.method})
    host.serve(slow) do
      Implementation.new.method("wait") do |_args, ctx|
        wait_abort(ctx.signal)
        seen_abort = true
      end
    end
    ref = host.hold(slow, nil, principal: {user: "u"})
    ref.ready.wait
    call = Future(JSON::Any?).run { ref.call("wait") }
    tick
    host.invalidate_principal { |principal| principal["user"]?.try(&.as_s?) == "u" }
    ref.status.should eq RefStatus::Gone
    call.wait
    seen_abort.should be_true
    chord_error(ErrorCode::Gone) { ref.call("wait") }
    fresh = host.hold(slow, nil, principal: {user: "u"})
    fresh.ready.wait
    fresh.status.should eq RefStatus::Live
  end

  it "state members are late-bound readables: values, then snapshot/reset/ops events" do
    host = quiet_host
    serve_doc(host)
    editor = host.hold(DOC, {id: "3"}, principal: {role: "editor"})
    shapes = [] of String?
    editor.on_shape { |shape| shapes << shape.variant }
    events = [] of JSON::Any
    values = [] of JSON::Any
    editor.state("view").events { |event| events << event_json(event) }
    editor.state("view").subscribe { |value| values << value }
    editor.ready.wait
    editor.variant.should eq "editor"
    editor.call("edit", {text: "hi"})
    shapes.should eq ["editor"]
    events.should eq [j(%(["snap",{"text":""}])), j(%(["ops",[["r",{"text":"hi"}]]]))]
    values.should eq [j(%({"text":""})), j(%({"text":"hi"}))]
  end
end

describe "host: registries" do
  it %(only objects of lifetime "host" register; tables follow registration order) do
    routes = C.define_registry(String, "t.routes")
    host = quiet_host
    host.serve(empty_contract("t.routes-a"), lifetime: :host) do |_input, _principal, scope|
      scope.register(routes, {"GET /a" => "a", "GET /c" => "c"})
      Implementation.new
    end
    host.serve(empty_contract("t.routes-b"), lifetime: :host) do |_input, _principal, scope|
      scope.register(routes, {"GET /b" => "b"})
      Implementation.new
    end
    tables = [] of Array(String)
    host.registry(routes).subscribe { |table| tables << table.keys }
    host.ready
    host.registry(routes).table.keys.should eq ["GET /a", "GET /c", "GET /b"]
    host.registry(routes).get("GET /b").should eq "b"
    tables.last.should eq ["GET /a", "GET /c", "GET /b"]

    lazy = empty_contract("t.lazy-register")
    host.serve(lazy) do |_input, _principal, scope|
      scope.register(routes, {"x" => "x"})
      Implementation.new
    end
    expect_raises(ChordError, /only objects of lifetime "host" may register/) { host.hold(lazy).ready.wait }
  end

  it "rejects conflicting registrations" do
    routes = C.define_registry(String, "t.routes")
    errors = [] of Exception
    host = quiet_host(errors)
    %w[t.conflict-a t.conflict-b].each do |name|
      host.serve(empty_contract(name), lifetime: :host) do |_input, _principal, scope|
        scope.register(routes, {"same" => name})
        Implementation.new
      end
    end
    eventually { errors.any? { |error| error.message.to_s.includes?("registry_conflict") } }
  end
end

describe "host: composition" do
  it "reference state members are sources for listeners and derivations" do
    host = quiet_host
    serve_source(host)
    mirror_contract = C.local("t.mirror", version: 1, input: T.object, members: {copy: T.number, doubled: T.number})
    host.serve(mirror_contract) do |_input, _principal, scope|
      source = scope.get(SOURCE)
      copy = scope.state("copy", T.number, 0)
      scope.on("follow", source.state("n")) { |value, ctx| copy.replace(ctx, value) }
      doubled = scope.derive([source.state("n")]) { |(current)| (current.as_i? || 0) * 2 }
      Implementation.new.state("copy", copy).state("doubled", doubled)
    end
    mirror = host.hold(mirror_contract)
    mirror.ready.wait
    eventually { mirror.state("copy").value == JSON::Any.new(1_i64) }
    mirror.state("doubled").value.should eq JSON::Any.new(2_i64)
    host.hold(SOURCE).call("set", 5)
    eventually { mirror.state("copy").value == JSON::Any.new(5_i64) }
    mirror.state("doubled").value.should eq JSON::Any.new(10_i64)
  end

  it "ctx.get acts as the root principal at ingress and as the host inside objects" do
    host = C.create_host(self: {kind: "host"}, principal_key: ->(principal : JSON::Any) { principal.to_json },
      on_error: ->(_error : Exception) { })
    seen = [] of JSON::Any
    who = C.local("t.who", version: 1, input: T.object, members: {ping: C.method})
    front = C.local("t.front", version: 1, input: T.object, members: {relay: C.method})
    host.serve(who) do |_input, principal|
      seen << principal
      Implementation.new.method("ping") { nil }
    end
    host.serve(front) do |_input, principal|
      seen << principal
      Implementation.new.method("relay") { |_args, ctx| ctx.get(who).call("ping", ctx) }
    end
    host.root(principal: {user: "guest"}) { |ctx| ctx.get(front).call("relay", ctx) }
    seen.should eq [j(%({"user":"guest"})), j(%({"kind":"host"}))]
  end

  it "calling a reference inside a factory throws not_ready" do
    host = quiet_host
    serve_source(host)
    eager = empty_contract("t.eager-call")
    host.serve(eager) do |_input, _principal, scope|
      scope.get(SOURCE).call("set", 1)
      Implementation.new
    end
    chord_error(ErrorCode::NotReady) { host.hold(eager).ready.wait }
  end

  it "binds an older consumer through an accepts adapter and refuses one without" do
    host = quiet_host
    v1 = C.local("t.renamed", version: 1, input: T.object, members: {label: C.method(nil, T.string)})
    v2 = C.local("t.renamed", version: 2, input: T.object, members: {heading: C.method(nil, T.string)})
    v3 = C.local("t.renamed", version: 3, input: T.object, members: {title: C.method(nil, T.string)})
    adapters = {1 => ->(current : Implementation) { current.dup.tap { |view| view["label"] = current["heading"] } }}
    host.serve(v2, accepts: adapters) { Implementation.new.method("heading") { "Todos" } }
    host.get(v1).call("label").should eq JSON::Any.new("Todos")
    host.get(v2).call("heading").should eq JSON::Any.new("Todos")
    chord_error(ErrorCode::ContractMismatch) { host.hold(v3) }
  end

  it "reads opaque and exposed members as their native type" do
    host = quiet_host
    native = C.local("t.native", version: 1, input: T.object, members: {
      plain:  C.opaque("t.plain@1"),
      handle: C.opaque("t.handle@1"),
    })
    host.serve(native) do |_input, _principal, scope|
      handle = scope.resource("handle", version: 1) { [1, 2] }
      Implementation.new.opaque("plain", "text").expose("handle", scope.expose(handle))
    end
    ref = host.get(native)
    ref.opaque("plain", String).should eq "text"
    ref.opaque("handle", Array(Int32)).should eq [1, 2]
    expect_raises(TypeCastError) { ref.opaque("plain", Int32) }
  end

  it "a ChordError from a factory keeps its code through dependents" do
    host = quiet_host
    secret = empty_contract("t.secret")
    page = empty_contract("t.page")
    host.serve(secret) { raise C.forbidden("not for you") }
    host.serve(page) do |_input, _principal, scope|
      scope.get(secret)
      Implementation.new
    end
    chord_error(ErrorCode::Forbidden) { host.hold(page).ready.wait }
  end
end

describe "principals" do
  it "factories see the caller; code inside objects acts as the host" do
    host = C.create_host(self: {kind: "host"}, principal_key: ->(principal : JSON::Any) {
      principal["kind"].as_s == "guest" ? "guest:#{principal["id"]}" : principal["kind"].as_s
    })
    who = C.local("t.who", version: 1, input: T.object, members: {who: C.method(nil, T.string)})
    facet = C.define_facet("who") do |api|
      api.serve(who) do |_input, principal|
        created = principal["kind"].as_s == "guest" ? "guest #{principal["id"]}" : principal["kind"].as_s
        Implementation.new.method("who") { |_args, ctx| "#{created}, called by #{ctx.principal["kind"]}" }
      end
    end
    host.install(facet)
    guest = host.hold(who, nil, principal: {kind: "guest", id: "g1"})
    result = host.root(principal: {kind: "guest", id: "g1"}) { |ctx| guest.call("who", ctx) }
    result.should eq JSON::Any.new("guest g1, called by host")
    host.close
  end

  it "the host's own principal is recognized by key: an equal object reaches the same objects" do
    host = C.create_host(self: {kind: "host"}, principal_key: ->(principal : JSON::Any) { principal["kind"].as_s })
    who = C.local("t.who", version: 1, input: T.object, members: {who: C.method(nil, T.string)})
    created = 0
    host.serve(who) do
      created += 1
      Implementation.new.method("who") { "one" }
    end
    own = host.hold(who)
    equal = host.hold(who, nil, principal: {kind: "host"})
    own.ready.wait
    equal.ready.wait
    created.should eq 1
    host.invalidate_principal({kind: "host"})
    own.status.should eq RefStatus::Live
    host.close
  end
end
