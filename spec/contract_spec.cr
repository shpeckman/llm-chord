# spec/contract_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private VIEW = T.object({text: T.string})

private def chat_v1 : RemoteContract
  C.remote("t.chat",
    version: 1,
    input: T.object({session: T.string, conversation: T.number(default: 0)}),
    host: C.host_family("session:", "session"),
    variants: {
      viewer:      C.variant(state: {view: VIEW}),
      participant: C.variant(
        state: {view: VIEW},
        methods: {send: C.method(T.object({text: T.string}), T.object({id: T.number}))},
      ),
    })
end

private def with_variant(contract : RemoteContract, kind : String, variant : VariantDef) : RemoteContract
  variants = contract.definition.variants.dup
  variants[kind] = variant
  C.remote(contract.name, contract.definition.copy_with(variants: variants))
end

private def methods_of(members) : Description
  C.local("t.methods", version: 1, input: T.object, members: members).description
end

private def mismatch?(& : ->) : Bool
  yield
  false
rescue error : ChordError
  error.code.contract_mismatch?
end

describe "contracts" do
  it "normalizes input and omits defaults from the identity" do
    input = chat_v1.input
    a = Schema.normalize(input, j(%({"session":"s","extra":1})), "input")
    a.should eq j(%({"session":"s","conversation":0}))
    b = Schema.normalize(input, j(%({"conversation":0,"session":"s"})), "input")
    Schema.canonical_identity(input, a).should eq Schema.canonical_identity(input, b)
    Schema.canonical_identity(input, a).should eq %({"session":"s"})
    error = expect_raises(ChordError) { Schema.normalize(input, j(%({"session":1})), "input") }
    error.code.invalid?.should be_true
    error.reason.should eq "input"
  end

  it "fingerprints are stable and description-based" do
    copy = C.remote("t.chat", chat_v1.definition)
    copy.fingerprint.should eq chat_v1.fingerprint
    C.remote("t.chat", chat_v1.definition.copy_with(version: 2)).fingerprint.should_not eq chat_v1.fingerprint
  end

  it "rejects reserved member names and opaque remote members" do
    expect_raises(ArgumentError, /reserved/) do
      C.local("t.x", version: 1, input: T.object, members: {status: C.method})
    end
    expect_raises(ArgumentError, /opaque/) do
      C.remote("t.x", version: 1, input: T.object, host: C.host_named("server"),
        variants: {a: C.variant(state: {h: C.opaque("x@1")})})
    end
  end

  it "covers additive changes and refuses breaking ones" do
    additive = with_variant(chat_v1, "participant", C.variant(
      state: {view: T.object({text: T.string, extra: T.number})},
      methods: {send: C.method(
        T.object({text: T.string, urgent: T.optional(T.boolean)}),
        T.object({id: T.number, at: T.number}),
      )},
    ))
    C.coverage(additive.description, chat_v1.description).should be_nil
    C.bind(additive, nil, chat_v1).should be_nil

    required = with_variant(chat_v1, "participant", C.variant(
      state: {view: VIEW},
      methods: {send: C.method(T.object({text: T.string, urgent: T.boolean}), T.object({id: T.number}))},
    ))
    C.coverage(required.description, chat_v1.description).not_nil!.should match(/arguments/)
    mismatch? { C.bind(required, nil, chat_v1) }.should be_true

    retyped = with_variant(chat_v1, "viewer", C.variant(state: {view: T.object({text: T.number})}))
    C.coverage(retyped.description, chat_v1.description).not_nil!.should match(/state/)
  end

  it "describes methods without arguments or result and matches their presence" do
    none = methods_of({m: C.method})
    none.variants[""]["m"].json.should eq j(%({"kind":"method"}))
    with_args = methods_of({m: C.method(T.string)})
    with_result = methods_of({m: C.method(nil, T.number)})
    C.coverage(none, none).should be_nil
    C.coverage(with_args, none).not_nil!.should match(/arguments/)
    C.coverage(none, with_args).not_nil!.should match(/arguments/)
    C.coverage(with_result, none).should be_nil
    C.coverage(none, with_result).not_nil!.should match(/result/)
  end

  it "binds other versions only through accepts adapters" do
    v2 = C.remote("t.chat", chat_v1.definition.copy_with(version: 2, variants: {"viewer" => C.variant(state: {body: VIEW})}))
    mismatch? { C.bind(v2, nil, chat_v1) }.should be_true
    adapter = ->(current : JSON::Any) { current }
    C.bind(v2, {1 => adapter}, chat_v1).should eq adapter
    mismatch? { C.bind(v2, {3 => adapter}, chat_v1) }.should be_true
  end

  it "compares opaque members by name@version and function members structurally" do
    a = C.local("t.idx", version: 1, input: T.object, members: {
      harness:  C.opaque("h@1"),
      onChange: C.method(T.function([T.string], T.void)),
    })
    members = a.definition.members.dup
    members["harness"] = C.opaque("h@2")
    b = C.local("t.idx", a.definition.copy_with(members: members))
    C.coverage(b.description, a.description).not_nil!.should match(/opaque/)
    Schema.fits?(T.function([T.unknown], T.void), T.function([T.string], T.void)).should be_true
    Schema.fits?(T.function([T.string], T.void), T.function([T.unknown], T.void)).should be_false
  end

  it "refuses a moved type across placements" do
    moved = C.remote("t.chat", chat_v1.definition.copy_with(host: C.host_named("server")))
    C.coverage(moved.description, chat_v1.description).should eq "host"
    error = expect_raises(ChordError) { C.bind(moved, nil, chat_v1) }
    error.message.not_nil!.should contain "lives on server, the consumer expects session:<session>"
  end

  it "validates headers, variants, and member kinds" do
    expect_raises(ArgumentError, "contract name is empty") { C.local("", version: 1, input: T.object) }
    expect_raises(ArgumentError, "contract version must be a positive integer") { C.local("t.x", version: 0, input: T.object) }
    expect_raises(ArgumentError, /has no variants/) do
      C.remote("t.x", version: 1, input: T.object, host: C.host_named("s"), variants: {} of String => VariantDef)
    end
    expect_raises(ArgumentError, /needs `host`/) do
      C.remote("t.x", version: 1, input: T.object, host: HostNamed.new(""), variants: {a: C.variant})
    end
    expect_raises(ArgumentError, "member n is both state and method in t.x.a") do
      C.remote("t.x", version: 1, input: T.object, host: C.host_named("s"),
        variants: {a: C.variant(state: {n: T.number}, methods: {n: C.method})})
    end
    expect_raises(ArgumentError, "methods.n is not a method()") do
      C.remote("t.x", version: 1, input: T.object, host: C.host_named("s"), variants: {a: C.variant(methods: {n: T.number})})
    end
    expect_raises(ArgumentError, "opaque id must be name@version: x") { C.opaque("x") }
  end

  it "rebuilds contracts from descriptions with the same fingerprint" do
    token = C.contract_from_description(JSON.parse(chat_v1.description.to_json))
    token.fingerprint.should eq chat_v1.fingerprint
    token.should be_a(RemoteContract)
    token.as(RemoteContract).host.should eq chat_v1.host
    C.bind(chat_v1, nil, token).should be_nil
    TypeBox::Value.check(DESCRIPTION_SCHEMA, chat_v1.description.json).should be_true
    error = expect_raises(ChordError) { C.contract_from_description(j(%({"name":"t","scope":"local","version":1,"host":{"name":"s"}}))) }
    error.reason.should eq "token"
  end

  it "reports whether a method takes arguments" do
    C.takes_no_args?(chat_v1, "send").should be_false
    local = C.local("t.n", version: 1, input: T.object, members: {bump: C.method, set: C.method(T.number)})
    C.takes_no_args?(local, "bump").should be_true
    C.takes_no_args?(local, "set").should be_false
    C.takes_no_args?(local, "missing").should be_false
  end
end

describe "placement" do
  it "resolves hosts from placements and inputs" do
    named = C.host_named("server")
    family = C.host_family("session:", "session")
    C.resolve_host("t", named, j("{}")).should eq "server"
    C.resolve_host("t", family, j(%({"session":"S1"}))).should eq "session:S1"
    error = expect_raises(ChordError) { C.resolve_host("t.note", family, j(%({"session":""}))) }
    error.reason.should eq "placement"
    error.message.should eq "invalid/placement: t.note: input field session names no host"
    C.placed_on?(family, "session:S1").should be_true
    C.placed_on?(family, "session:").should be_false
    C.placed_on?(named, "server").should be_true
    C.placement_text(family).should eq "session:<session>"
    expect_raises(ArgumentError) { C.host_named("") }
    expect_raises(ArgumentError) { C.host_family("p", "") }
  end
end
