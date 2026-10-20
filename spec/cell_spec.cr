# spec/cell_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private ITEM  = T.object({id: T.number, label: T.string})
private ITEMS = T.object({items: T.array(ITEM), count: T.number})

private LIST = C.local("t.list",
  version: 1,
  input: T.object,
  members: {
    list:   ITEMS,
    labels: T.array(T.string),
    push:   C.method(ITEM),
    set:    C.method(ITEMS),
  })

private def serve_list(host : Host) : Nil
  host.serve(LIST) do |_input, _principal, scope|
    list = scope.state("list", ITEMS, {items: [] of JSON::Any, count: 0})
    labels = scope.derive([list]) { |(value)| value["items"].as_a.map(&.["label"]) }
    Implementation.new
      .state("list", list)
      .state("labels", labels)
      .method("push") do |item, ctx|
        list.change(ctx) do |draft|
          draft["items"] << item.not_nil!
          draft["count"] = draft["count"].as_i + 1
        end
      end
      .method("set") { |value, ctx| list.replace(ctx, value.not_nil!) }
  end
end

describe "state cells" do
  it "publishes snapshots then exact ops; derivations follow" do
    host = quiet_host
    serve_list(host)
    ref = host.hold(LIST)
    events = [] of StateEvent
    labels = [] of StateEvent
    ref.state("list").events { |event| events << event }
    ref.state("labels").events { |event| labels << event }
    ref.call("push", {id: 1, label: "a"})
    event_json(events[0]).should eq j(%(["snap",{"items":[],"count":0}]))
    events[1].ops.map(&.to_tuple.to_json).sort.should eq [
      %(["p",["items"],0,0,[{"id":1,"label":"a"}]]),
      %(["s",["count"],1]),
    ]
    events[1].value.should eq j(%({"items":[{"id":1,"label":"a"}],"count":1}))
    ref.state("labels").value.should eq j(%(["a"]))
    labels.map(&.kind).should eq [StateEvent::Kind::Snap, StateEvent::Kind::Ops]
    ref.call("set", {items: [] of JSON::Any, count: 0})
    ref.state("labels").value.should eq j("[]")
  end

  it "supports primitive cells and value-returning updates" do
    host = quiet_host
    counter = C.local("t.prim", version: 1, input: T.object, members: {n: T.number, inc: C.method(nil, T.number)})
    host.serve(counter) do |_input, _principal, scope|
      n = scope.state("n", T.number, 0)
      Implementation.new.state("n", n).method("inc") do |_args, ctx|
        n.update(ctx) { |value| value.as_i + 1 }
        n.value
      end
    end
    ref = host.hold(counter)
    ref.ready.wait
    events = [] of JSON::Any
    values = [] of JSON::Any
    ref.state("n").events { |event| events << event_json(event) }
    ref.state("n").subscribe { |value| values << value }
    ref.call("inc").should eq JSON::Any.new(1_i64)
    ref.call("inc").should eq JSON::Any.new(2_i64)
    values.should eq [JSON::Any.new(0_i64), JSON::Any.new(1_i64), JSON::Any.new(2_i64)]
    events.should eq [j(%(["snap",0])), j(%(["ops",[["r",1]]])), j(%(["ops",[["r",2]]]))]
  end

  it "rejects an updated value that does not fit the schema, even outside dev mode" do
    host = quiet_host
    box = C.local("t.box", version: 1, input: T.object, members: {put: C.method})
    host.serve(box) do |_input, _principal, scope|
      list = scope.state("list", T.array(T.number), [] of JSON::Any)
      Implementation.new.method("put") { |_args, ctx| list.update(ctx) { 1 } }
    end
    error = expect_raises(ChordError) { host.hold(box).call("put") }
    error.code.should eq ErrorCode::Invalid
  end

  it "validates initial values always and writes only in dev mode" do
    bad = C.local("t.bad-initial", version: 1, input: T.object)
    host = quiet_host
    host.serve(bad) do |_input, _principal, scope|
      scope.state("x", T.object({n: T.number}), {n: "no"})
      Implementation.new
    end
    expect_raises(ChordError, /initial value of state x/) { host.hold(bad).ready.wait }

    lax = quiet_host
    serve_list(lax)
    lax.hold(LIST).call("set", {items: [] of JSON::Any, count: "x"})

    dev = C.create_host(self: {kind: "host"}, dev: true, on_error: ->(_error : Exception) { })
    serve_list(dev)
    ref = dev.hold(LIST)
    error = expect_raises(ChordError) { ref.call("set", {items: [] of JSON::Any, count: "x"}) }
    error.code.should eq ErrorCode::Invalid
    error.reason.should eq "state"
    ref.state("list").value.should eq j(%({"items":[],"count":0}))
  end

  it "rejects writes from inside a factory and placeholder use before activation" do
    host = quiet_host
    writer = C.local("t.writer", version: 1, input: T.object)
    captured = host.root { |ctx| ctx }
    not_ready_inside = false
    host.serve(writer) do |_input, _principal, scope|
      x = scope.state("x", T.object, {} of String => JSON::Any)
      r = scope.resource("r", version: 1) { 1 }
      begin
        r.value
      rescue error : ChordError
        not_ready_inside = error.code.not_ready?
      end
      x.replace(captured, {} of String => JSON::Any)
      Implementation.new
    end
    expect_raises(ChordError, /read_only/) { host.hold(writer).ready.wait }
    not_ready_inside.should be_true
  end

  it "listeners run each event in a fresh root; tasks get an abortable ctx" do
    host = quiet_host
    emitter = Emitter.new
    watcher = C.local("t.watcher", version: 1, input: T.object, members: {seen: T.object({sum: T.number})})
    roots = Set(String).new
    task_aborted = false
    host.serve(watcher) do |_input, _principal, scope|
      seen = scope.state("seen", T.object({sum: T.number}), {sum: 0})
      source = scope.resource("source", version: 1) { emitter }
      scope.on("onEvent", source, ->(events : Emitter) { events }) do |value, ctx|
        roots << ctx.root_id
        seen.change(ctx) { |draft| draft["sum"] = draft["sum"].as_i + value.as_i }
      end
      scope.task do |ctx|
        wait_abort(ctx.signal)
        task_aborted = true
      end
      Implementation.new.state("seen", seen)
    end
    ref = host.hold(watcher)
    ref.ready.wait
    emitter.emit(2)
    emitter.emit(3)
    eventually { ref.state("seen").value == j(%({"sum":5})) }
    roots.size.should eq 2
    ref.release
    eventually { emitter.size == 0 && task_aborted }
  end

  it "re-entrant writes publish in adoption order; derivations never go stale" do
    host = quiet_host
    echo = C.local("t.reentrant", version: 1, input: T.object,
      members: {n: T.number, d: T.number, set: C.method(T.number)})
    host.serve(echo) do |_input, _principal, scope|
      n = scope.state("n", T.number, 0)
      d = scope.derive([n]) { |(value)| value.as_i * 2 }
      scope.on("bump", n) { |value, ctx| n.replace(ctx, 2) if value.as_i == 1 }
      Implementation.new.state("n", n).state("d", d).method("set") { |value, ctx| n.replace(ctx, value.not_nil!) }
    end
    ref = host.hold(echo)
    ref.ready.wait
    values = [] of JSON::Any
    replica = JSON::Any.new(nil)
    ref.state("n").events do |event|
      replica = event.kind.ops? ? Delta.apply_immutable(replica, event.ops) : event.value
      values << replica
    end
    doubled = [] of JSON::Any
    ref.state("d").subscribe { |value| doubled << value }
    ref.call("set", 1)
    eventually { values.size == 3 }
    values.should eq [0, 1, 2].map { |value| JSON::Any.new(value.to_i64) }
    ref.state("d").value.should eq JSON::Any.new(4_i64)
    doubled.should eq [0, 2, 4].map { |value| JSON::Any.new(value.to_i64) }
  end
end
