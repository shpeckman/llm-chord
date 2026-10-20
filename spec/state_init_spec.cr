# spec/state_init_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private NOTES_SCHEMA = T.array(T.string)

private NOTES = C.local("t.notes",
  version: 1,
  input: T.object,
  members: {
    notes: NOTES_SCHEMA,
    count: T.number,
    has:   C.method(T.string, T.boolean),
    add:   C.method(T.string),
  })

private def notes_impl(notes : Cell, scope : ObjectScope) : Implementation
  count = scope.derive([notes]) { |(list)| list.as_a.size }
  Implementation.new
    .state("notes", notes)
    .state("count", count)
    .method("has") { |note| notes.value.as_a.includes?(note.not_nil!) }
    .method("add") { |note, ctx| notes.change(ctx) { |draft| draft << note.not_nil! } }
end

describe "state init" do
  it "runs after the resources are open and before the object goes live: nothing sees another value" do
    host = quiet_host
    loaded = Channel(JSON::Any).new(1)
    log = [] of String
    host.serve(NOTES) do |_input, _principal, scope|
      db = scope.resource("db", version: 1) do
        log << "open"
        loaded
      end
      notes = scope.state("notes", NOTES_SCHEMA) do
        log << "init"
        db.value.receive
      end
      scope.on("notes", notes) { |list| log << "listener #{list.as_a.join(",")}" }
      scope.task { log << "task #{notes.value.as_a.join(",")}" }
      notes_impl(notes, scope)
    end
    ref = host.hold(NOTES)
    seen = [] of JSON::Any
    ref.state("notes").subscribe { |value| seen << value }
    has = Future(JSON::Any?).run { host.root { |ctx| ref.call("has", "a", ctx) } }
    eventually { log.includes?("init") }
    ref.status.should eq RefStatus::Loading
    loaded.send(j(%(["a","b"])))
    has.wait.should eq JSON::Any.new(true)
    ref.state("count").value.should eq JSON::Any.new(2_i64)
    eventually { log.size == 4 }
    log.should eq ["open", "init", "listener a,b", "task a,b"]
    seen.should eq [j(%(["a","b"]))]
  end

  it "an init cell cannot be read inside the factory" do
    host = quiet_host
    host.serve(NOTES) do |_input, _principal, scope|
      notes = scope.state("notes", NOTES_SCHEMA) { [] of String }
      notes.value
      notes_impl(notes, scope)
    end
    error = expect_raises(ChordError) { host.hold(NOTES).ready.wait }
    error.code.should eq ErrorCode::NotReady
  end

  it "a throwing or invalid init fails the activation and closes its resources; the next get tries again" do
    host = quiet_host
    failure = "db down".as(String?)
    result = j("[]")
    closed = [] of String
    host.serve(NOTES) do |_input, _principal, scope|
      scope.resource("db", version: 1, close: ->(db : String) { closed << db }) { "db" }
      notes = scope.state("notes", NOTES_SCHEMA) do
        failure.try { |message| raise message }
        result
      end
      notes_impl(notes, scope)
    end
    expect_raises(ChordError, /db down/) { host.hold(NOTES).ready.wait }
    closed.should eq ["db"]
    failure = nil
    result = j("[1]")
    error = expect_raises(ChordError) { host.hold(NOTES).ready.wait }
    error.code.should eq ErrorCode::Invalid
    closed.should eq ["db", "db"]
    result = j(%(["ok"]))
    ref = host.hold(NOTES)
    ref.ready.wait
    ref.state("notes").value.should eq j(%(["ok"]))
  end

  it "init runs in a root: it can call other objects" do
    host = quiet_host
    source = C.local("t.source", version: 1, input: T.object, members: {all: C.method(nil, NOTES_SCHEMA)})
    host.serve(source) { Implementation.new.method("all") { ["from source"] } }
    host.serve(NOTES) do |_input, _principal, scope|
      notes = scope.state("notes", NOTES_SCHEMA) { |ctx| ctx.get(source).call("all", ctx) }
      notes_impl(notes, scope)
    end
    ref = host.hold(NOTES)
    ref.ready.wait
    ref.state("notes").value.should eq j(%(["from source"]))
  end
end
