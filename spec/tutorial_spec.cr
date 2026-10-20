# spec/tutorial_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private TODO_LABEL = C.local("tutorial.todos",
  version: 1,
  input: T.object({list: T.string}),
  members: {label: C.method(nil, T.string)})

private TODO = T.object({text: T.string, done: T.boolean})
private ROWS = T.array(TODO)

private TODO_STORE = C.local("tutorial.todos",
  version: 1,
  input: T.object({list: T.string}),
  members: {
    label:     C.method(nil, T.string),
    rows:      ROWS,
    openCount: T.number,
    add:       C.method(T.object({text: T.string})),
    finish:    C.method(T.object({index: T.integer})),
    reset:     C.method(ROWS),
  })

private TODOS = C.remote("tutorial.todo-view",
  version: 1,
  input: T.object({list: T.string}),
  host: C.host_named("server"),
  variants: {
    viewer: C.variant(state: {rows: ROWS}),
    editor: C.variant(state: {rows: ROWS}, methods: {add: C.method(T.object({text: T.string}))}),
  })

private class SavedDb
  getter saved = [] of String
end

private def todo_store(input : JSON::Any, scope : ObjectScope) : Implementation
  list = input["list"].as_s
  rows = scope.state("rows", ROWS, [] of JSON::Any)
  open_count = scope.derive([rows]) { |(todos)| todos.as_a.count { |todo| !todo["done"].as_bool } }
  Implementation.new
    .method("label") { "Todos for #{list}" }
    .state("rows", rows)
    .state("openCount", open_count)
    .method("add") { |args, ctx| rows.change(ctx) { |draft| draft << {text: args.not_nil!["text"], done: false} } }
    .method("finish") do |args, ctx|
      index = args.not_nil!["index"].as_i
      rows.change(ctx) do |draft|
        todo = draft[index]? || raise C.invalid("args", "No such todo")
        todo["done"] = true
      end
    end
    .method("reset") { |args, ctx| rows.replace(ctx, args.not_nil!, diff: true) }
end

private def serve_store(host : Host) : Nil
  host.serve(TODO_STORE) { |input, _principal, scope| todo_store(input, scope) }
end

private def serve_views(host : Host) : Nil
  host.serve(TODOS) do |input, principal, scope|
    raise C.forbidden("This list is not shared") unless input["list"].as_s == "family"
    store = scope.get(TODO_STORE, {list: input["list"]})
    next Implementation.new("viewer").state("rows", store.state("rows")) if principal.as_s == "guest"
    Implementation.new("editor")
      .state("rows", store.state("rows"))
      .method("add") do |args, ctx|
        text = args.not_nil!["text"].as_s
        raise C.invalid("args", "A todo needs text") if text.strip.empty?
        store.call("add", {text: text}, ctx)
      end
  end
end

private def chord_error(code : ErrorCode, &) : ChordError
  error = expect_raises(ChordError) { yield }
  error.code.should eq code
  error
end

describe "tutorial" do
  it "01: objects live inside hosts" do
    host = C.create_host(self: "server", name: "todo-server")
    host.name.should eq "todo-server"
    host.close
  end

  it "02: first contract, factory, reference and root" do
    host = C.create_host(self: "server")
    host.serve(TODO_LABEL) { |input| Implementation.new.method("label") { "Todos for #{input["list"]}" } }
    result = host.root do |ctx|
      todos = ctx.get(TODO_LABEL, {list: "family"})
      todos.call("label", ctx)
    end
    result.should eq JSON::Any.new("Todos for family")
  ensure
    host.try &.close
  end

  it "03: cells publish values and derivations" do
    host = C.create_host(self: "server", dev: true)
    serve_store(host)
    todos = host.get(TODO_STORE, {list: "family"})
    counts = [] of JSON::Any
    stop = todos.state("openCount").subscribe { |value| counts << value }
    host.root do |ctx|
      todos.call("add", {text: "Buy milk"}, ctx)
      todos.call("finish", {index: 0}, ctx)
      todos.call("reset", [] of JSON::Any, ctx)
    end
    counts.should eq [JSON::Any.new(0_i64), JSON::Any.new(1_i64), JSON::Any.new(0_i64)]
    todos.state("rows").value.should eq j("[]")
    stop.call
    todos.release
  ensure
    host.try &.close
  end

  it "04: holds, asynchronous resources and release" do
    database_contract = C.local("tutorial.database",
      version: 1,
      input: T.object,
      members: {db: C.opaque("tutorial.database@1")})
    saved_todos = C.local("tutorial.saved-todos",
      version: 1,
      input: T.object({list: T.string}),
      members: {add: C.method(T.object({text: T.string}))})
    host = C.create_host(self: "server")
    opens = 0
    closed = Channel(Nil).new(1)
    host.serve(database_contract) do |_input, _principal, scope|
      db = scope.resource("db", version: 1, close: ->(_db : SavedDb) { notify(closed) }) do
        opens += 1
        SavedDb.new
      end
      Implementation.new.expose("db", scope.expose(db))
    end
    serve_store(host)
    host.serve(saved_todos, linger: Time::Span.zero) do |input, _principal, scope|
      database = scope.get(database_contract)
      todos = scope.get(TODO_STORE, {list: input["list"]})
      Implementation.new.method("add") do |args, ctx|
        text = args.not_nil!["text"]
        database.opaque("db", SavedDb).not_nil!.saved << text.as_s
        todos.call("add", {text: text}, ctx)
      end
    end
    saved = host.get(saved_todos, {list: "family"})
    database = host.get(database_contract)
    host.root { |ctx| saved.call("add", {text: "Buy milk"}, ctx) }
    database.opaque("db", SavedDb).not_nil!.saved.should eq ["Buy milk"]
    opens.should eq 1
    statuses = [] of RefStatus
    saved.on_status { |status| statuses << status }
    database.release
    saved.release
    closed.receive
    saved.status.should eq RefStatus::Released
    statuses.should contain RefStatus::Released
  ensure
    host.try &.close
  end

  it "05: principals select views of one shared store" do
    host = C.create_host(name: "server", self: "server", principal_key: ->(principal : JSON::Any) { principal.as_s })
    serve_store(host)
    serve_views(host)
    owner = host.get(TODOS, {list: "family"}, principal: "owner")
    guest = host.get(TODOS, {list: "family"}, principal: "guest")
    owner.variant.should eq "editor"
    guest.variant.should eq "viewer"
    host.root(principal: "owner") { |ctx| owner.call("add", {text: "Buy milk"}, ctx) }
    guest.state("rows").value.should eq j(%([{"text":"Buy milk","done":false}]))
    chord_error(ErrorCode::NotInVariant) { guest.call("add", {text: "Not allowed"}) }
    chord_error(ErrorCode::Invalid) { owner.call("add", {text: " "}) }
  ensure
    host.try &.close
  end

  it "07: listeners react and tasks start fresh calls" do
    activity_contract = C.local("tutorial.activity", version: 1, input: T.object, members: {seen: T.number})
    host = C.create_host(self: "server")
    serve_store(host)
    observed = Channel(Nil).new(1)
    seeded = Channel(Nil).new(1)
    stopped = Channel(Nil).new(1)
    host.serve(activity_contract) do |_input, _principal, scope|
      todos = scope.get(TODO_STORE, {list: "family"})
      seen = scope.state("seen", T.number, 0)
      scope.on("rows", todos.state("rows")) do |rows, ctx|
        size = rows.as_a?.try(&.size) || 0
        seen.replace(ctx, size)
        notify(observed) if size == 1
      end
      scope.task do |ctx|
        todos.call("add", {text: "Review the list"}, ctx)
        notify(seeded)
        wait_abort(ctx.signal)
        notify(stopped)
      end
      Implementation.new.state("seen", seen)
    end
    activity = host.get(activity_contract)
    seeded.receive
    observed.receive
    activity.state("seen").value.should eq JSON::Any.new(1_i64)
    activity.release
    stopped.receive
  ensure
    host.try &.close
  end

  it "08: plugins contribute registry entries and expose callbacks" do
    actions = C.define_registry(Proc(Ctx, Int64), "tutorial.actions")
    menu = C.local("tutorial.menu", version: 1, input: T.object)
    click = nil.as(Proc(Int64)?)
    store_facet = C.define_facet("todo-store") { |api| api.serve(TODO_STORE) { |input, _principal, scope| todo_store(input, scope) } }
    menu_facet = C.define_facet("todo-menu", uses: [TODO_STORE]) do |api|
      api.serve(menu, lifetime: :host) do |_input, _principal, scope|
        todos = scope.get(TODO_STORE, {list: "family"})
        scope.register(actions, {
          "addSample" => ->(ctx : Ctx) do
            todos.call("add", {text: "Try plugins"}, ctx)
            todos.state("openCount").value.as_i64
          end,
        })
        Implementation.new
      end
      click = -> { api.root { |ctx| api.registry(actions).get("addSample", ctx).not_nil!.call(ctx) } }
    end
    host = C.create_host(self: "server")
    host.load([menu_facet, store_facet], await_host_objects: false)
    host.ready
    click.not_nil!.call.should eq 1
    host.registry(actions).table.size.should eq 1
  ensure
    host.try &.close
  end

  it "10: stub a provider with a fake facet and check error codes" do
    host = C.create_host(name: "server", self: "server", dev: true)
    received = [] of String
    fake = C.define_facet("fake-store") do |api|
      api.serve(TODO_STORE) do |input, _principal, scope|
        todo_store(input, scope).method("add") { |args| received << args.not_nil!["text"].as_s }
      end
    end
    host.load([fake])
    serve_views(host)
    owner = host.get(TODOS, {list: "family"}, principal: "owner")
    owner.variant.should eq "editor"
    owner.call("add", {text: "Test delegation"})
    received.should eq ["Test delegation"]
    chord_error(ErrorCode::Invalid) { owner.call("add", {text: ""}) }
    owner.release
    chord_error(ErrorCode::Released) { owner.call("add", {text: "Too late"}) }
  ensure
    host.try &.close
  end

  it "11: short roots release temporary holds" do
    host = C.create_host(self: "server")
    serve_store(host)
    screen = host.get(TODO_STORE, {list: "family"})
    host.root do |ctx|
      temporary = ctx.get(TODO_STORE, {list: "family"})
      temporary.call("add", {text: "Keep roots short"}, ctx)
    end
    screen.state("openCount").value.should eq JSON::Any.new(1_i64)
    screen.release
  ensure
    host.try &.close
  end
end
