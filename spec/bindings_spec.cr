# spec/bindings_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private NOTE_SCHEMA = T.array(T.string)

private NOTES = C.remote("t.e8-notes", version: 1,
  input: T.object({list: T.optional(T.string(default: "main"))}),
  host: C.host_named("server"),
  variants: {
    main: C.variant(state: {notes: NOTE_SCHEMA, title: T.string},
      methods: {add: C.method(T.string), rename: C.method(T.string)}),
  })

private def serve_notes(host : Host) : Nil
  host.serve(NOTES) do |_input, _principal, scope|
    notes = scope.state("notes", NOTE_SCHEMA, [] of JSON::Any)
    title = scope.state("title", T.string, "untitled")
    Implementation.new("main")
      .state("notes", notes)
      .state("title", title)
      .method("add") { |text, ctx| notes.change(ctx) { |draft| draft << text.not_nil! } }
      .method("rename") { |text, ctx| title.replace(ctx, text.not_nil!) }
  end
end

private record Setup, server : Host, browser : Host, link : CountingLink

private def setup(window : Int64? = nil, linger : Hash(String, Time::Span)? = nil, linger_cap : Int32 = 4) : Setup
  server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
  serve_notes(server)
  down, up = C.memory_link_pair
  if window
    server.accept(down, principal: {user: "u"}, window: window)
  else
    server.accept(down, principal: {user: "u"})
  end
  link = CountingLink.new(up)
  browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
    upstream: C.upstream(link, principal: {kind: "server"}), linger: linger, linger_cap: linger_cap)
  Setup.new(server, browser, link)
end

private def size_of(ref : Ref, member : String) : Int32
  ref.state(member).value.as_a.size
rescue ChordError
  -1
end

describe "shared bindings: traffic" do
  it "N references to one object: one hold, one snapshot per member, one frame per change, one release" do
    s = setup
    panel_contract = C.local("t.e8-panel", version: 1, input: T.object, members: {count: T.number})
    s.browser.serve(panel_contract) do |_input, _principal, scope|
      notes = scope.get(NOTES)
      Implementation.new.state("count", scope.derive([notes.state("notes")]) { |(list)| list.as_a.size })
    end
    a = s.browser.hold(NOTES)
    b = s.browser.hold(NOTES, {list: "main"})
    panel = s.browser.hold(panel_contract)
    [a, b, panel].each(&.ready.wait)
    s.browser.root { |ctx| ctx.get(NOTES).state("title").value }.should eq JSON::Any.new("untitled")
    s.link.count(:sent, "hold").should eq 1
    snaps = state_frames(s.link.received).select { |frame| frame.string("as") == "snap" }
    snaps.map(&.string("m")).sort.should eq ["notes", "title"]

    before = state_frames(s.link.received).size
    a.call("add", "milk")
    eventually { size_of(a, "notes") == 1 && size_of(b, "notes") == 1 && panel.state("count").value == JSON::Any.new(1_i64) }
    tick
    (state_frames(s.link.received).size - before).should eq 1

    sent = s.link.traffic(:sent).size
    a.release
    panel.release
    sleep 5.milliseconds
    s.link.traffic(:sent).size.should eq sent
    b.release
    eventually { s.link.count(:sent, "release") == 1 }
    s.browser.close
    s.server.close
  end

  it "a held reference stays subscribed without listeners; values are readable at once after ready" do
    s = setup
    notes = s.browser.hold(NOTES)
    notes.ready.wait
    notes.state("notes").value.should eq j("[]")
    notes.call("add", "bread")
    eventually { size_of(notes, "notes") == 1 }
    notes.state("title").value.should eq JSON::Any.new("untitled")
    s.browser.close
    s.server.close
  end
end

describe "shared bindings: linger" do
  it "a lingering binding keeps its hold and state; a reference taken meanwhile costs nothing on the link" do
    s = setup(linger: {NOTES.name => 40.milliseconds})
    first = s.browser.get(NOTES)
    frames = s.link.traffic(:received).size
    first.release
    sleep 10.milliseconds
    s.link.count(:sent, "release").should eq 0
    3.times do
      again = s.browser.get(NOTES)
      again.state("notes").value.should eq j("[]")
      again.release
    end
    s.link.count(:sent, "hold").should eq 1
    s.link.traffic(:received).size.should eq frames
    eventually { s.link.count(:sent, "release") == 1 }
    s.browser.close
    s.server.close
  end

  it "at most `cap` bindings linger: the least recently released goes first" do
    s = setup(linger: {NOTES.name => 10.seconds}, linger_cap: 1)
    a = s.browser.get(NOTES, {list: "a"})
    b = s.browser.get(NOTES, {list: "b"})
    a.release
    sleep 5.milliseconds
    s.link.count(:sent, "release").should eq 0
    b.release
    eventually { s.link.count(:sent, "release") == 1 }
    release = s.link.sent.find! { |frame| frame.t == "release" }
    hold_of_a = s.link.sent.find! { |frame| frame.t == "hold" && frame["input"]["list"] == "a" }
    release.int("id").should eq hold_of_a.int("id")
    s.browser.close
    s.server.close
  end
end

describe "shared bindings: identity" do
  it "normalized-equal inputs and equal principal keys share; other principals and fingerprints do not" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    notes_v2 = C.remote("t.e8-notes", version: 2, input: T.object({list: T.optional(T.string(default: "main"))}),
      host: C.host_named("server"), variants: {
      main: C.variant(state: {notes: NOTE_SCHEMA, title: T.string},
        methods: {add: C.method(T.string), rename: C.method(T.string), clear: C.method}),
    })
    server.serve(notes_v2, accepts: {1 => ->(current : Implementation) { current }}) do |_input, _principal, scope|
      notes = scope.state("notes", NOTE_SCHEMA, [] of JSON::Any)
      title = scope.state("title", T.string, "untitled")
      Implementation.new("main").state("notes", notes).state("title", title)
        .method("add") { nil }.method("rename") { nil }.method("clear") { nil }
    end
    down, up = C.memory_link_pair
    server.accept(down, principal: {worker: "w"}, kind: :host, name: "session:w")
    link = CountingLink.new(up)
    worker = Host.new(self: {kind: "host"}, name: "session:w", on_error: quiet_on_error,
      upstream: C.upstream(link, principal: {kind: "server"}))
    refs = [
      worker.hold(NOTES),
      worker.hold(NOTES, {list: "main"}),
      worker.hold(NOTES, nil, principal: {user: "a", grant: 1}),
      worker.hold(NOTES, nil, principal: {grant: 1, user: "a"}),
      worker.hold(NOTES, nil, principal: {user: "a", grant: 2}),
      worker.hold(notes_v2),
    ]
    refs.each(&.ready.wait)
    link.count(:sent, "hold").should eq 4
    worker.close
    server.close
  end
end

describe "hydration over a link" do
  matrix = C.remote("t.e8-matrix", version: 1, input: T.object({variant: T.string}), host: C.host_named("server"),
    variants: {
      values: C.variant(state: {none: T.null, empty: T.array(T.string), maybe: T.unknown}),
      bare:   C.variant(methods: {ping: C.method(nil, T.string)}),
      broken: C.variant(state: {n: T.number}),
    })

  it "null and empty values hydrate; a state-free variant is ready; a failed snapshot rejects" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    server.serve(matrix) do |input, _principal, scope|
      case input["variant"].as_s
      when "bare"
        Implementation.new("bare").method("ping") { "pong" }
      when "broken"
        source = scope.state("source", T.string, "not a number")
        Implementation.new("broken").state("n", scope.derive([source]) { |(text)| text })
      else
        none = scope.state("none", T.null, nil)
        empty = scope.state("empty", T.array(T.string), [] of JSON::Any)
        Implementation.new("values").state("none", none).state("empty", empty)
          .state("maybe", scope.derive([none]) { nil })
      end
    end
    down, up = C.memory_link_pair
    server.accept(down, principal: {user: "u"})
    browser = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
      upstream: C.upstream(up, principal: {kind: "server"}))
    values = browser.get(matrix, {variant: "values"})
    values.variant.should eq "values"
    values.state("none").value.should eq JSON::Any.new(nil)
    values.state("empty").value.should eq j("[]")
    values.state("maybe").value.should eq JSON::Any.new(nil)
    bare = browser.get(matrix, {variant: "bare"})
    bare.variant.should eq "bare"
    bare.call("ping").should eq JSON::Any.new("pong")
    expect_raises(ChordError) { bare.state("none").value }.code.should eq ErrorCode::NotInVariant
    broken = browser.hold(matrix, {variant: "broken"})
    expect_raises(ChordError) { broken.ready.wait }.code.should eq ErrorCode::Invalid
    broken.status.should eq RefStatus::Gone
    browser.close
    server.close
  end

  it "reading before the first hydration throws not_ready" do
    s = setup
    notes = s.browser.hold(NOTES)
    expect_raises(ChordError) { notes.state("notes").value }.code.should eq ErrorCode::NotReady
    notes.ready.wait
    notes.state("notes").value.should eq j("[]")
    s.browser.close
    s.server.close
  end
end

describe "method-only references (state: false)" do
  it "transfer no state alone; a full reference joining starts it once; its release stops it" do
    s = setup
    caller = s.browser.hold(NOTES, state: false)
    caller.ready.wait
    caller.call("add", "x")
    hold = s.link.sent.find! { |frame| frame.t == "hold" }
    hold["state"]?.should eq JSON::Any.new(false)
    state_frames(s.link.received).should be_empty
    expect_raises(ChordError) { caller.state("notes").value }.code.should eq ErrorCode::NotReady

    viewer = s.browser.hold(NOTES)
    viewer.ready.wait
    viewer.state("notes").value.should eq j(%(["x"]))
    s.link.count(:sent, "sub").should eq 1
    s.link.count(:sent, "hold").should eq 1
    viewer.release
    eventually { s.link.count(:sent, "unsub") == 1 }
    after = state_frames(s.link.received).size
    caller.call("add", "y")
    sleep 5.milliseconds
    state_frames(s.link.received).size.should eq after
    s.browser.close
    s.server.close
  end
end

describe "origins of client holds" do
  counter = C.remote("t.e8-counter", version: 1, input: T.object({session: T.string}),
    host: C.host_family("session:", "session"),
    variants: {main: C.variant(state: {n: T.number}, methods: {add: C.method(T.number)})})

  it "a relayed hold carries its client connection's id; the server's own holds carry none" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    worker = nil.as(Host?)
    to_worker = nil.as(CountingLink?)
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        existing = to_worker
        return_existing = !existing.nil?
        down, up = C.memory_link_pair
        created = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
          upstream: C.upstream(up, principal: {kind: "server"}))
        created.serve(counter) do |_input, _principal, scope|
          n = scope.state("n", T.number, 0)
          Implementation.new("main").state("n", n)
            .method("add") { |delta, ctx| n.replace(ctx, n.value.as_i + delta.not_nil!.as_i) }
        end
        unless return_existing
          worker = created
          to_worker = CountingLink.new(down)
        end
        to_worker.not_nil!.as(LLM::Chord::Link)
      end,
    ))
    browsers = [] of Tuple(Host, MemoryLink)
    browser = -> do
      down, up = C.memory_link_pair
      server.accept(down, principal: {guest: "g"})
      host = Host.new(self: {kind: "host"}, name: "browser", kind: :client, on_error: quiet_on_error,
        upstream: C.upstream(up, principal: {kind: "server"}))
      browsers << {host, up}
      {host, up}
    end
    origins = -> { worker.try(&.upstream).try(&.served.values.map { |served| served.as(ServedLocal).origin }) || [] of String? }
    one = browser.call
    two = browser.call
    one[0].hold(counter, {session: "S1"}).ready.wait
    two[0].hold(counter, {session: "S1"}).ready.wait
    own = server.hold(counter, {session: "S1"})
    own.ready.wait
    holds = to_worker.not_nil!.sent.select { |frame| frame.t == "hold" }
    holds.size.should eq 3
    relayed = holds.select { |frame| frame["origin"]? }
    relayed.size.should eq 2
    relayed[0]["origin"].should_not eq relayed[1]["origin"]
    holds.count { |frame| frame["origin"]?.nil? }.should eq 1

    before = origins.call.to_set
    one[1].close
    eventually { origins.call.compact.size == 1 }
    three = browser.call
    three[0].hold(counter, {session: "S1"}).ready.wait
    after = origins.call.compact
    after.size.should eq 2
    after.any? { |origin| !before.includes?(origin) }.should be_true
    server.close
  end

  it "an origin a client sends is ignored: the server stamps its own" do
    server = Host.new(self: {kind: "host"}, name: "server", on_error: quiet_on_error)
    to_worker = nil.as(CountingLink?)
    server.route("session:", Route.new(
      principal: ->(name : String) { {host: name} },
      authorize: ->(_principal : JSON::Any, _host : String) { true },
      resolve: ->(name : String) do
        down, up = C.memory_link_pair
        created = Host.new(self: {kind: "host"}, name: name, on_error: quiet_on_error,
          upstream: C.upstream(up, principal: {kind: "server"}))
        created.serve(counter) { |_input, _principal, scope| Implementation.new("main").state("n", scope.state("n", T.number, 0)).method("add") { nil } }
        link = CountingLink.new(down)
        to_worker = link
        link.as(LLM::Chord::Link)
      end,
    ))
    down, raw = C.memory_link_pair
    server.accept(down, principal: {guest: "g"})
    raw.receive { }
    raw.send(wire("hello", protocol: PROTOCOL_VERSION, name: "raw", kind: "client", codeVersion: 0))
    raw.send(wire("hold", id: 1, at: "session:S1", token: counter.description.json, input: j(%({"session":"S1"})),
      origin: "spoofed"))
    eventually { to_worker.try(&.sent.any? { |frame| frame.t == "hold" }) == true }
    hold = to_worker.not_nil!.sent.find! { |frame| frame.t == "hold" }
    hold["origin"]?.should_not be_nil
    hold["origin"].should_not eq "spoofed"
    server.close
  end
end

describe "protocol version 4" do
  it "a version 3 peer is refused; shapes carry no code version" do
    s = setup
    s.browser.hold(NOTES).ready.wait
    shape = s.link.received.find! { |frame| frame.t == "shape" }
    shape["codeVersion"]?.should be_nil
    shape["state"].as_a.map(&.as_s).sort.should eq ["notes", "title"]
    down, raw = C.memory_link_pair
    s.server.accept(down, principal: {user: "old"})
    closed = Channel(String).new(1)
    raw.on_close { |reason| closed.send(reason) }
    raw.receive { }
    raw.send(wire("hello", protocol: 3, name: "old", kind: "client", codeVersion: 0))
    closed.receive.should eq "protocol-version #{PROTOCOL_VERSION}"
    PROTOCOL_VERSION.should eq 4
    s.browser.close
    s.server.close
  end
end
