# llm-chord

A Crystal port of [`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).

The port currently covers chord's foundation layer:

- `LLM::Chord::Delta` — `@earendil-works/chord/delta`: transactional JSON
  revision tracking, structural diff, immutable apply, and the wire codec.
- `LLM::Chord.replicated_state` — chord's observable replicated state, either
  authoritative and mutable or attached to an external revision source.
- `LLM::Chord::Context` — `@earendil-works/chord/context`: explicit
  invocation-scoped values, cancellation, and telemetry spans.
- `LLM::Chord::Telemetry` — the parts of `@earendil-works/pi-telemetry` chord
  uses: span, metrics, propagation, and store contracts, the no-op context, the
  in-memory reference recorder, and `render_trace`.
- `LLM::Chord::Output` — `@earendil-works/chord/output`: bounded output
  streams and paced progress commits.
- `LLM::Chord::ChordError` — chord's error codes and helpers.
- `LLM::Chord.remote` / `.local` — contracts with placement, variants,
  versions, fingerprints, coverage, and binding; `LLM::Chord::Schema` —
  canonical JSON, `hash64`, input normalization and identity, and the `fits?`
  compatibility rule. Schemas are built with the `typebox` shard, which emits
  the same JSON Schema as TypeBox.
- `LLM::Chord::Host` — chord's single-process runtime: objects with cells,
  derivations, resources, listeners and tasks; references with variants,
  late binding and `accepts` adapters; roots and call contexts; lifetimes and
  linger; principals; facets; registries.
- Links — chord's wire protocol (version 4) between hosts: memory, IPC (Node's
  IPC channel format) and WebSocket links; remote references with shared
  bindings, units, flow control and consumer-side linger; relays and routes;
  principal stamping; packed payloads.
- `LLM::Chord::HostManager` — child host processes: the fork driver (process
  groups, an IPC channel on `NODE_CHANNEL_FD`), the manager, the child's
  control channel, and the kernel `process_lock`.

Reload and SQLite are not ported yet; see [ROADMAP.md](ROADMAP.md). Values are
Crystal's `JSON::Any`.

## Requirements

- Crystal `>= 1.21.0`

## Installation

```yaml
dependencies:
  llm-chord:
    github: shpeckman/llm-chord
```

llm-chord depends on the `typebox` shard, referenced in its `shard.yml` as a
sibling checkout (`path: ../typebox`).

Then `shards install`, and in your code:

```crystal
require "llm-chord"
```

## Tracking JSON deltas

```crystal
tracker = LLM::Chord::Delta.track(JSON.parse(%({"output":"","entries":[]})))

change = tracker.begin_change
change.state["output"] = change.state["output"].as_s + "done\n"
change.state["entries"] << {"id" => 1}
prepared = change.prepare

tracker.adopt(prepared)
tracker.value     # => {"output" => "done\n", "entries" => [{"id" => 1}]}
tracker.revision  # => 1

replica = LLM::Chord::Delta.apply_immutable(prepared.base, prepared.ops)
```

`tracker.value` is always the latest adopted immutable revision. `begin_change`
opens a copy-on-write draft over it; `prepare` materializes the candidate and
its operation batch without changing authority; `adopt` validates the
preparation and swaps the root. Unchanged subtrees are shared between
revisions.

### Ownership

Immutability is an ownership contract. Nothing is frozen, so an illegal
mutation is not detected; it silently corrupts state.

| Value | May it be mutated? |
| --- | --- |
| Root passed to `track`, `prepare_replace`, `replicated_state`, or `replace` | No. Ownership moved to the tracker. |
| `change.state` and handles read from it | Only while the change is open. After `prepare`, `abort`, or another adoption, every use raises `OverlayError`. Writes through a handle whose element was removed from the draft are ignored. |
| A value after placing it into a draft | Yes. The draft stored a validated clone. |
| `tracker.value`, `prepared.base`, retained older revisions | No. |
| `prepared.value`, `prepared.ops` and their payloads | No. Payloads may be shared with `prepared.value`. |
| `apply_immutable` / `apply_immutable_batches` inputs and result | No. The result shares containers with both inputs. |
| Values from replicated state (`value`, listener values) | No. Subscribers share the provider's containers. |
| Mutable replica passed to `apply` | Only through `apply`, with batches it owns exclusively. |
| Batch passed to `apply` | Consumed. `apply` adopts payload containers into the replica. |

### Lifecycle

- Several changes may be open or prepared from one revision. Adopting one
  makes all others stale: their drafts raise and `adopt` rejects them.
- `adopt` rejects foreign, aborted, stale, and already used preparations.
  `Change#abort` or `Prepared#abort` after `prepare` prevents adoption; the
  candidate stays readable.
- An empty `ops` means `prepared.value` is `prepared.base`. Adopting a no-op
  still advances `revision` and stales competitors.
- `prepare_replace(value)` is a whole-root operation, not a diff: its ops are
  `[Replace(value)]`, or empty when `value` is deeply equal to the current root.
- Roots must be JSON objects or arrays.

### Drafts

`Change#state` returns a `Draft`, a revocable handle over the draft:

- Reads: `[]`, `[]?` (keys and indices), `as_s`, `as_i`, `as_f`, `as_bool`,
  `null?`, `as_a` (`Array(Draft)`), `as_h` (`Hash(String, Draft)`), `string?`,
  `int`, `float`, `bool`, `array`, `object`, `size`, `empty?`, and `value` (a
  detached deep copy).
- Writes: `[]=`, `delete`, `<<`, `push`, `pop`, `shift`, `unshift`, `splice`,
  `delete_at`, `size=`, `reverse!`, `sort!` (with or without a block), `fill`,
  `copy_within`. Array indices follow JavaScript semantics where chord does
  (negative relative indices, clamped ranges, default sort by string form).
- Placed values are validated as strict JSON and cloned before the draft
  changes; placing a `Draft` clones its current content. Arrays stay dense:
  writing past the next index raises, `size=` grows with `null`.
- Held handles follow their element through reindexing; two handles to the
  same element see each other's writes.

## Operations

| Verb | Struct | Meaning |
|------|--------|---------|
| `r` | `Op::Replace` | Replace the whole value. |
| `s` | `Op::Set` | Set an object property or array element. |
| `d` | `Op::Delete` | Delete an object property or array element. |
| `a` | `Op::Append` | Append text to a string. |
| `t` | `Op::Truncate` | Remove `count` UTF-16 code units from a string's front. |
| `p` | `Op::Splice` | Splice an array. |
| `m` | `Op::Move` | Reorder an array: `new[i] = old[permutation[i]]`. |

`Op::Set`, `Delete`, `Append`, `Truncate`, `Splice`, and `Move` share the
`Op::Targeted` base with a `path`. Constructors validate: `s`/`d`/`a`/`t` need a
non-empty path, `__proto__`/`constructor`/`prototype` segments raise
`UnsafePathError`, counts must be non-negative, and permutations must be
bijections.

`Op#to_tuple` and `Op.from_tuple` convert to and from chord's decoded tuple form
(`["s", path, value]`), validating like chord's `assertValidOp`.
`Delta.assert_valid_wire_op` validates the wire form. `Op#replace?` and
`Delta.base?` classify replacements and base batches.

Batches are exact but not canonical: the same change may use different tuples,
and large edit sets may fold into a region splice, an ancestor `s`, or `r`.

## Diffing and applying

```crystal
ops = LLM::Chord::Delta.diff_revisions(before, after)

LLM::Chord::Delta.apply(replica, ops)                       # mutates and adopts payloads
LLM::Chord::Delta.apply_immutable(base, ops)                # copy-on-write, shares untouched subtrees
LLM::Chord::Delta.apply_immutable_batches(base, [b1, b2])   # one copy-on-write scope for a backlog
```

`diff_revisions` matches chord's algorithm, including identity-based array
anchoring: containers shared by both revisions anchor array alignment.

## Wire codec

```crystal
wire = LLM::Chord::Delta::Encoder.new.encode(ops)   # Array(WireOp)
ops  = LLM::Chord::Delta::Decoder.new.decode(wire)
```

Paths are interned on their second use (`["#", id, path]`), and an op on the
same path as the previous one omits it. Use one encoder/decoder pair per
ordered state stream: path ids span batches, and an `r` resets both
dictionaries. The decoder validates every tuple.

## Context

```crystal
request = LLM::Chord::ContextKey(String).new("request")
context = LLM::Chord::Context::BACKGROUND.with_value(request, "abc")
context.value(request)  # => "abc"
```

Contexts are immutable; every `with_*` derives a child and never changes the
parent. Keys match by identity. `Context::BACKGROUND` and `Context::TODO` are
the empty roots.

### Cancellation

```crystal
child, controller = context.with_cancel
controller.abort("shutting down")          # or abort(an_exception)
child.abort_signal.not_nil!.aborted?       # => true

cleanup = child.without_abort_signal       # mandatory cleanup ignores caller cancellation
linked = context.with_abort_signal(other_controller.signal)

value = child.await(channel)               # receive, or raise the abort reason
value = child.await { slow_work }          # runs on its own fiber; cancellation stops waiting only
```

An `AbortSignal` has `aborted?`, `reason` (an `Exception`; `AbortError` by
default), `on_abort { |reason| }` (returns a remover), `throw_if_aborted`, and
`AbortSignal.any(signals)`. A child signal aborts when its own controller or any
ancestor aborts; siblings are unaffected.

### Telemetry

```crystal
recorder = LLM::Chord::Telemetry::InMemoryTelemetryContext.new
recorder.start_span(LLM::Chord::Telemetry::SpanOptions.new("app.request")) do |span|
  context = LLM::Chord::Context::BACKGROUND.with_telemetry(span)
  context.trace_in("app.load") do |child|
    child.telemetry.add_event("cache.miss")
    child.trace_in("app.read") { |nested| read_account(nested) }
  end
end
```

`context.telemetry` is the context's span, or `Telemetry::NOOP` when none was
set. `trace_in(options)` (or `trace_in(name)`) runs the block in a child span
and passes a derived context; the block's value and exceptions pass through.
There is no ambient current span.

## Telemetry

`Telemetry::TelemetryContext` starts spans around a block
(`start_span(options) { |span| }`); a `Telemetry::TelemetrySpan` is also the
parent context for its children and records `add_event`, `add_link`,
`merge_attributes`, and `status=`. Contexts may expose `metrics` (`counter`,
`up_down_counter`, `histogram`) and `propagation` (`inject` / `extract` of a
string `Carrier`).

- `Telemetry::NOOP`, `NOOP_METRICS`, `NOOP_PROPAGATION` record nothing.
- `Telemetry::InMemoryTelemetryContext` is the reference recorder. A raised
  exception marks its span as an error unless a status was set; recording on a
  settled span is ignored and its children are inert. `recorded_spans` and
  `recorded_metrics` return detached snapshots, and it implements
  `TelemetryStore` (`find_traces` with paging, `get_trace`, `find_metrics`).
- `Telemetry.render_trace(spans)` renders stored spans as an indented forest.
- `Telemetry.attributes(key: value, ...)` builds an `Attributes` hash.

## Output

```crystal
limits = LLM::Chord::Output::Limits.tail(200, 64 * 1024)   # max_lines, max_bytes
buffer = LLM::Chord::Output::Buffer.new(limits)
buffer.push(bytes)              # String or Bytes; UTF-8 split across chunks is decoded
buffer.end
buffer.snapshot                 # => Bounded(text, dropped_bytes, dropped_lines)
```

- `Output.bound(text, limits)` keeps whole lines (head or tail) within both
  limits; a single line longer than `max_bytes` is cut on a character
  boundary. It returns an `Excerpt` (`text`, `bytes`, `dropped_bytes`,
  `dropped_lines`).
- `Output.sanitize(text)` removes control characters except tab and newline.
- `Buffer` costs time proportional to each chunk, keeps exact totals for the
  whole stream, decodes bytes like a WHATWG UTF-8 decoder (invalid sequences
  become U+FFFD), drops a byte-order mark only at the very start, and accepts
  `Skip` counts of omitted output for tail retention.
- `Output::Progress.new(write, on_error, min_interval_ms, clock)` paces commits:
  the first change after a pause commits at once; each commit then delays the
  next by at least `min_interval_ms` and by its written size at 100 KiB/s.
  `mark` schedules a commit, `mark_and_wait` returns a `Waiter` (`wait` raises
  if the commit failed), and `stop` waits for the commit in flight and returns
  the waiters no commit covered. `write` returns the bytes it wrote and runs on
  its own fiber. `clock` defaults to `Output::SYSTEM_CLOCK`.

## Errors

`ChordError` carries a `code` (`ErrorCode`: `Aborted`, `ContractMismatch`,
`Forbidden`, `Gone`, `Invalid`, `NotInVariant`, `NotReady`, `Released`,
`Superseded`, `Unavailable`, `UpgradeConflict`, `UpgradeRequired`), an optional
`reason`, `details`, and `cause`; its message is `code/reason: message`.
`Superseded` and `UpgradeConflict` are `retryable?`. Helpers:
`LLM::Chord.chord_error?`, `.forbidden`, `.invalid`, `.as_chord_error` (keeps a
`ChordError`, wraps anything else as `unavailable`), and `.run_all` (runs every
step, then raises the one error or an `AggregateError`).

## Contracts

A contract declares a type: its name, version, input schema, and members. A
remote type also declares where its objects live. Schemas come from
`TypeBox::Type`.

```crystal
T = TypeBox::Type
C = LLM::Chord

View = T.object({text: T.string})

Chat = C.remote("t.chat",
  version: 1,
  input: T.object({session: T.string, conversation: T.number(default: 0)}),
  host: C.host_family("session:", "session"),
  variants: {
    viewer:      C.variant(state: {view: View}),
    participant: C.variant(
      state: {view: View},
      methods: {send: C.method(T.object({text: T.string}), T.object({id: T.number}))},
    ),
  })

Index = C.local("t.index", version: 1, input: T.object, members: {
  harness: C.opaque("harness@1"),
  count:   T.integer,
  bump:    C.method,
})

Chat.fingerprint                     # => 16 hex digits, identical to chord's
Chat.description.json                # the description that travels in tokens
```

- `C.method(args = nil, result = nil)`: no `args` means the method takes no
  arguments; no `result` means it returns nothing.
- `C.opaque("name@version")`: a native in-process object, for local contracts
  only.
- Placement: `C.host_named("server")`, or `C.host_family(prefix, key)`, which
  puts an object on `prefix` + the input's string field `key`.
  `C.resolve_host`, `C.placed_on?`, and `C.placement_text` work on either.
- Members named `variant`, `status`, `ready`, `shape`, `error`, `onShape`,
  `onStatus`, `release`, `then`, or `contract` are rejected, as are opaque
  members in remote contracts. Construction errors raise `ArgumentError`.
- `RemoteDef` and `LocalDef` are records: `C.remote(name, Chat.definition.copy_with(version: 2))`
  derives a new version.
- The fingerprint is `hash64(canonical_json(description))`, so a contract
  built here and the same contract built by chord share a fingerprint.

### Compatibility

`C.coverage(provider_description, consumer_description)` returns `nil` when the
provider covers the consumer, or the reason it does not (`"input"`,
`"participant.send arguments"`, `"host"`, ...). `C.bind(provider, accepts,
consumer)` returns `nil` for a direct binding, the consumer version's adapter
from `accepts` (a `Hash(Int32, A)` of any adapter type), or raises
`contract_mismatch`:

- equal fingerprints bind directly;
- a different placement never binds;
- the same version binds when the provider covers the consumer;
- another version needs an adapter in `accepts`.

`C.contract_from_description(json)` rebuilds a consumer token from a received
description (raising `invalid/token` when malformed); `DESCRIPTION_SCHEMA`
validates one. `C.takes_no_args?(contract, name)` tells how a method is called.

### Schema helpers

`LLM::Chord::Schema` ports chord's `schema.ts`:

| Function | Behavior |
| --- | --- |
| `canonical_json(value)` | sorted-key JSON, numbers and strings as `JSON.stringify` writes them |
| `hash64(text)` | two FNV-1a lanes over UTF-16 code units, 16 hex digits |
| `deep_equal?(a, b)` | equality by canonical JSON |
| `normalize(schema, value, what)` | clone, apply defaults, strip unknown fields, validate; raises `invalid/input` |
| `canonical_identity(schema, value)` | canonical JSON with fields equal to their default omitted |
| `assert_valid(reason, what, schema, value)` | raises `invalid/<reason>` with the first three errors |
| `fits?(sub, sup)` | conservative structural subtyping used by coverage |

## Objects and hosts

A host serves types. An object is one instance of a type at an address: the
type, its normalized input, and the principal it was created for. Its factory
runs once and returns the implementation; references reach the object through
the consumer's contract.

```crystal
T = TypeBox::Type
C = LLM::Chord

Rows = T.array(T.object({text: T.string, done: T.boolean}))

TodoStore = C.local("todos", version: 1, input: T.object({list: T.string}), members: {
  label:     C.method(nil, T.string),
  rows:      Rows,
  openCount: T.number,
  add:       C.method(T.object({text: T.string})),
})

host = C.create_host(self: "server")

host.serve(TodoStore) do |input, _principal, scope|
  rows = scope.state("rows", Rows, [] of JSON::Any)
  open_count = scope.derive([rows]) { |(todos)| todos.as_a.count { |todo| !todo["done"].as_bool } }
  C::Implementation.new
    .method("label") { "Todos for #{input["list"]}" }
    .state("rows", rows)
    .state("openCount", open_count)
    .method("add") { |args, ctx| rows.change(ctx) { |draft| draft << {text: args.not_nil!["text"], done: false} } }
end

todos = host.get(TodoStore, {list: "family"})
stop = todos.state("openCount").subscribe { |count| puts count }   # 0, then 1
host.root { |ctx| todos.call("add", {text: "Buy milk"}, ctx) }
todos.call("label")                                                   # => "Todos for family"
stop.call
todos.release
host.close
```

### Hosts

`C.create_host(**options)` is `Host.new(**options)` (a macro, so symbols such
as `kind: :client` still autocast):

| Option | Meaning |
| --- | --- |
| `self` (required) | The principal of the host's own code: its roots, code inside its objects, and its host-lifetime objects. |
| `name` | Default `"host"`. Remote types must be placed on it to be served here. |
| `principal_key` | `Proc(JSON::Any, String)` mapping a principal to its object key. Default: canonical JSON. A principal with the same key as `self` is the host's own. |
| `dev` | Validates every cell write, and every value exposed as a remote state member, against its schemas. |
| `on_error` | Receives errors from background work (disposal, listeners, tasks, host objects). Default: printed to `STDERR`. |
| `ready_timeout` | How long an activation waits for its references to be ready and hydrated, and an awaited `get` for its reference (`unavailable/ready_timeout`). Default 60 s; `nil` waits forever. |
| `kind` | `:host` (default) or `:client` (a browser: never carries roots). |
| `upstream` | The link to the parent: `C.upstream(link, principal: ..., **link_options)`. Also `connect` later. |
| `linger`, `linger_cap` | Consumer-side linger of remote references: `{type_name => Time::Span}`; at most `linger_cap` (default 4) bindings linger. |

Principals and inputs are anything that serializes to JSON (named tuples,
hashes, strings, `JSON::Any`).

- `serve(contract, lifetime:, linger:, accepts:) { |input, principal, scope| implementation }`
  registers a factory. `lifetime: :host` creates the type's one object at once
  (a local type whose input accepts `{}`); every `get` reaches it, it is created
  for the host principal, and only such objects may register into registries.
  A referenced object is disposed when its last reference is released, after
  `linger`. `accepts` maps older consumer versions to adapters
  (`Proc(Implementation, Implementation)`).
- `get(type, input = nil, principal: nil, signal: nil, state: true)` blocks until the
  reference is ready (live, with its state members hydrated) and returns it.
  It raises the activation error, `aborted`, or `unavailable/ready_timeout`,
  and releases the reference then. `hold` returns the reference at once, maybe
  still `loading`. `state: false` makes a remote reference method-only.
- `root(principal: nil, signal: nil) { |ctx| ... }` runs a call tree and
  returns the block's value. References taken with `ctx.get` are released when
  the root ends.
- `install(facet, await_host_objects: true)`, `load(facets, await_host_objects: true)`
  and `ready` start and await host-lifetime objects; `load` installs every
  facet before awaiting any.
- `invalidate_principal { |principal| bool }` or `invalidate_principal(pattern)`
  force-disposes the objects of matching principals (never the host's own);
  a pattern matches principals whose listed fields are deep-equal.
- `close` disposes every object, holders before what they hold, then closes
  the links.

### Factories

The factory gets the normalized input, the principal, and an `ObjectScope`
(chord's `self`) through which it declares what the object owns. Names are
unique per kind, and declarations are validated at activation.

| Declaration | Meaning |
| --- | --- |
| `scope.state(name, schema, initial)` | A cell with an initial value (always validated). |
| `scope.state(name, schema) { \|ctx\| value }` | A cell filled by an init that runs in its own root after the object's resources are open and its references live, before the object goes live. |
| `scope.get(type, input = nil, principal: nil)` | A reference the object holds for its lifetime. Holding cycles raise `invalid/cycle`. |
| `scope.resource(name, version:, deps:, exclusive:, close:) { \|signal\| value }` | Opened before the object goes live (after its `deps`, references or resources), closed in reverse order after it is disposed. `value` raises `not_ready` while any factory runs. |
| `scope.on(name, source) { \|event, ctx\| }` | A listener on a readable (current value, then every new one) or a `Subscribable`. `on(name, resource)` listens to the resource's value; `on(name, resource, selector)` to `selector.call(value)`. Each event runs in a fresh root. |
| `scope.task { \|ctx\| }` | Long-running work of the live object, aborted at disposal. Calls made with its ctx start fresh roots. |
| `scope.derive(sources) { \|values\| value }` | A synchronous projection of readables, recomputed atomically with object writes and on publication of other sources. |
| `scope.register(registry, entries)` | Registry entries (host-lifetime objects only). |
| `scope.expose(resource)` | A member backed by a resource's value. |

The factory returns an `Implementation`: `Implementation.new(variant = nil)`
with `method(name) { |args, ctx| result }`, `state(name, readable)`,
`expose(name, exposed)`, and `opaque(name, value)`, plus `[]`, `[]?`, `[]=`,
`delete`, `keys`, `dup` and `variant=` for adapters. Method results convert to
JSON; `nil` means no result. A remote contract's implementation names its
variant and may only contain that variant's members.

### References

| Member | Meaning |
| --- | --- |
| `call(name, args = nil, ctx = nil)` | Calls a method and returns its result (`JSON::Any?`). Without a ctx, or with a task's, it runs in a fresh root. Remote arguments and results are validated at the provider. |
| `state(name)` | A late-bound `Readable` following the member: reading raises `not_ready` until live and `not_in_variant` outside the variant. A listener added early gets its snapshot once live; a changed source is announced as a reset. |
| `opaque(name, T)` | An opaque or exposed member as `T`. |
| `status`, `ready`, `error` | `RefStatus` (`Loading`, `Live`, `Released`, `Gone`), a `Future(Nil)`, and why the reference is gone. |
| `variant`, `shape`, `on_shape`, `on_status` | The current variant and shape, and listeners for their changes. |
| `release` | Releases the reference; calls then raise `released`. |

`Future(T)` has `wait` (blocks, raising a rejection), `await_settled`,
`settled?`, `rejected?`, `error`, `on_settle`, and `Future.run { }` to run a
block on its own fiber.

### Cells and derivations

`Cell#change(ctx) { |draft| }` mutates a `Delta::Draft` of the value and
publishes exactly the changed paths. `Cell#update(ctx) { |value| new_value }`
replaces the value with the block's result, always validated.
`Cell#replace(ctx, value, diff: nil)` replaces the whole value: subscribers get
a structural diff when `diff` is true, or by default when the new value shares
containers with the old one, and otherwise one `r` op. Cells reject writes
while a factory runs (`invalid/read_only`).

Readables (`Cell`, `Derived`, reference members) have `value`,
`subscribe { |value| }` (current value at once, then each new one) and
`events { |event| }`: a `StateEvent` with `kind` (`Snap`, `Ops`, `Reset`),
`value` and `ops`. Each write adopts its revision and every derived one before
any observer runs, and notifications are delivered in adoption order, so a
re-entrant write never overtakes the one being published.

### Contexts

A `Ctx` has `signal`, `root_id`, `code_version`, `principal` (the caller at
ingress, the host inside objects) and `get(type, input = nil, principal: nil)`.
A ctx expires when its call settles: using it later raises `aborted/expired`.

### Facets and registries

```crystal
Actions = C.define_registry(Proc(C::Ctx, Int64), "actions")
Menu = C.local("menu", version: 1, input: T.object)

store = C.define_facet("store") { |api| api.serve(TodoStore) { |input, principal, scope| todo_store(input, scope) } }
menu = C.define_facet("menu", uses: [TodoStore]) do |api|
  api.serve(Menu, lifetime: :host) do |_input, _principal, scope|
    todos = scope.get(TodoStore, {list: "family"})
    scope.register(Actions, {
      "addSample" => ->(ctx : C::Ctx) { todos.call("add", {text: "Try"}, ctx); todos.state("openCount").value.as_i64 },
    })
    C::Implementation.new
  end
end

host.load([menu, store])
host.root { |ctx| host.registry(Actions).get("addSample", ctx).try &.call(ctx) }
```

`todo_store(input, scope)` stands for the factory body of the first example.
A `FacetApi` has `serve`, `root`, `registry`, `name`, and `signal` (aborted
when the facet is removed or the host closes). `define_registry(V, name,
conflict: :error)` refuses two objects registering one key; `:last` keeps the
later one. `RegistryView` has `table(ctx = nil)`, `get(key, ctx = nil)` and
`subscribe { |table, code_version| }`; tables keep registration order.

## Links

A link is an ordered frame channel between two hosts. A remote type's placement
decides where its objects live; a reference to one on another host is a
`RemoteRef`, a view onto the host's shared binding for that object.

```crystal
server = C.create_host(self: {kind: "host"}, name: "server")
server.serve(Board) { |_input, principal, scope| ... }

down, up = C.memory_link_pair
server.accept(down, principal: {guest: "g1"})
browser = C.create_host(self: {kind: "host"}, name: "browser", kind: :client,
  upstream: C.upstream(up, principal: {kind: "server"}))

board = browser.get(Board)
board.call("add", "hello")
board.state("notes").subscribe { |notes| puts notes }
```

- `accept(link, principal:, kind: :client, name: nil, restamp: nil, max_calls: nil, **link_options)`
  accepts a peer. Everything it asks acts as `principal`; frames cannot claim
  another. A `:host` peer needs its `name`, must announce it, and is reachable
  at it. `restamp` gives a new principal on `invalidate_principal` (or `nil` to
  close the link). `max_calls` answers calls beyond it with
  `unavailable/too_many_calls`.
- `connect(link, principal:, **link_options)` sets (or replaces, after a
  reconnect) the link to the parent; remote references re-hold over it and keep
  their last values meanwhile. The parent's own requests act as `principal`.
- `route(prefix, Route.new(authorize:, resolve:, principal:))` relays holds for
  hosts named `prefix…`: `authorize` runs before and after `resolve` (which
  returns a `Link`, spawning the host if needed); `principal` is what the
  routed host acts as when it calls back.
- `LinkOptions`: `ping_interval` (15 s), `ping_timeout` (45 s), `window`
  (256 KiB of unacknowledged frames; `nil` never holds state back),
  `pending_cap` (4 windows of waiting ops), `on_protocol_mismatch`
  (`Proc(Int32, Int32?, Nil)`: local and peer version).
- Transports: `C.memory_link_pair` (`MemoryLink#sever` simulates a dead
  network); `C.ipc_link(IpcChannel.new(io))` or `IpcChannel.from_env` (Node's
  IPC format: one JSON message per line, frames wrapped as `{"chord2": frame}`);
  `WebSocketLink.connect(url)` or `C.web_socket_link(socket)`.
  `C.accept_web_sockets(host, **link_options) { |context| principal_or_nil }`
  returns an `HTTP::WebSocketHandler` that accepts every socket as a client
  stamped with the authenticator's principal.
- Frames are `Frame` objects (`t`, `[]`, `payload`, `packed`); `Wire` builds,
  validates and encodes them, and `Wire.inflate_message` turns a binary
  WebSocket message back into text. Payloads above `PACK_THRESHOLD` (64 KiB of
  JSON) travel deflated; relays forward them unread.
- A hold implies the state of its variant: the provider sends a unit (the shape,
  then a snapshot of each member the consumer lacks), then delta-encoded ops.
  When the peer's acknowledgements lag a window behind, state waits in one slot
  per stream (ops coalesced, or replaced by a reset beyond `pending_cap`), while
  results and first units go out at once.
- Remote references to one object share one hold per host, principal key and
  contract fingerprint. `Ref#ready` resolves once the binding has its shape and
  every state member's value.

## Child host processes

```crystal
manager = C.create_host_manager(C.fork_driver("./worker", init: {greeting: "hi"}, lock: "session-S1"))
instance = manager.start                       # spawned, linked, and reported ready
server.accept(instance.link, principal: {worker: "w1"}, kind: :host, name: "w1")
manager.stop                                   # shutdown, then SIGKILL to the group after the grace period
```

In the child:

```crystal
control = C.child_control                      # the IPC channel from NODE_CHANNEL_FD
control.lock                                   # the manager's lock, before opening storage
host = C.create_host(self: {kind: "host"}, name: "w1",
  upstream: C.upstream(control.link, principal: {kind: "server"}))
greeting = control.init.wait
control.on_shutdown { host.close; exit 0 }
control.ready
```

- `C.fork_driver(entry, args:, env:, init:, lock:, on_output:, on_message:)`
  spawns `entry` with `posix_spawn` as the leader of its own process group, with
  stdin on `/dev/null` and an IPC socket on fd 3 (`NODE_CHANNEL_FD=3`,
  `NODE_CHANNEL_SERIALIZATION_MODE=json`), so the child may be a Crystal host or
  a Node process. When the leader exits, the whole group is killed. A lock the
  parent inherited is not passed on.
- `HostManager` (`status`, `instance`, `liveness`, `start`, `stop`, `replace`)
  serializes its operations, waits `ready_timeout` (30 s) for `ready`, and
  stops the child when `keep_alive.call(liveness)` returns false (checked every
  `check_interval`). `Liveness` has `booting`, `active_calls`, `viewers`,
  `durable_tasks` and `idle_for` (since the busy → idle transition).
- `ChildControl` has `init` (a `Future(JSON::Any?)`), `lock`, `ready`,
  `fatal(error)`, `report(active_calls:, viewers:, durable_tasks:)`,
  `on_shutdown`, `channel` and `link`.
- `C.process_lock(name)` holds a kernel lock for the process's lifetime: a
  Linux abstract socket named like chord's (`\0chord2-` + 32 hex digits of
  SHA-256), so Crystal and Node processes exclude each other; a socket file in
  the temporary directory elsewhere. It returns the release proc and raises
  `unavailable/locked` when another process holds it.

## Replicated state

```crystal
state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))

stop = state.subscribe do |value, context, delivery|
  # delivery.kind : DeliveryKind::Hydrate | Update, delivery.sequence : Int64
end

state.change(LLM::Chord::Context::BACKGROUND) { |draft| draft["n"] = 1 }
state.replace(LLM::Chord::Context::BACKGROUND, JSON.parse(%({"fresh":true})))
stop.call
```

- A successful `change` publishes exactly one revision; if the block raises,
  the value and sequence are unchanged and the draft is revoked. No-op changes
  do not publish. Changes and replacements cannot be made from inside a change
  block.
- Each subscription serializes its callbacks: hydration first, then updates.
  At most 100 deliveries wait behind the running callback; on overflow only the
  newest is kept (plus a not-yet-started hydration), so sequences may skip.
- `subscribe(async: true)` runs the subscription's callbacks on their own fiber,
  one at a time, so a slow listener never blocks the publisher.
- Listener exceptions are reported and delivery continues. Mutable states
  report by raising in a spawned fiber.
- Unsubscribing discards pending deliveries; it neither waits for nor aborts a
  running callback.

`LLM::Chord.replicated_state(source, on_error)` attaches a publication-only state
to a `ReplicatedStateSource`. The source's attachment provides a `Snapshot` and
delivers `SourceFrame`s (`cursor`, `value`, `ops`, `context`) in cursor order. A
cursor gap, an unsafe cursor, or a failing attachment disposes the attachment
and reports to `on_error` (an `AggregateError` when disposal also fails).
`dispose` is idempotent.

## Public API reference

- `LLM::Chord::Delta.track(initial) : Tracker`
- `Tracker#value`, `#revision`, `#begin_change`, `#prepare_replace`, `#adopt`
- `Change#state`, `#prepare`, `#abort`
- `Prepared#base`, `#value`, `#ops`, `#base_revision`, `#abort`
- `Draft` (see above), `OverlayError`
- `LLM::Chord::Delta.diff_revisions`, `.apply`, `.apply_immutable`, `.apply_immutable_batches`
- `LLM::Chord::Delta::Encoder#encode`, `Decoder#decode`
- `LLM::Chord::Delta.overlap(a, b, scan, probe = 64, max_candidates = 8)`
- `Op`, `Op.from_tuple`, `Op#to_tuple`, `Op#replace?`, `Op::Targeted#path`
- `LLM::Chord::Delta.base?`, `.assert_safe_path`, `.assert_permutation`, `.assert_valid_wire_op`
- Types: `Seg = String | Int32`, `Path = Array(Seg)`, `WireOp = JSON::Any`
- Errors: `UnsafePathError`, `PathError`, `OverlayError`
- `LLM::Chord::Json.deep_copy`, `.copy_json`, `.container?`, `.identical?`,
  `.equal?`, `.to_any`, `.to_struct`, `.from_struct`, `.valid?`, `.strict?`,
  `.validate!`, `.js_string`, `.number_text`
- `LLM::Chord::Context` (`BACKGROUND`, `TODO`, `#value`, `#with_value`, `#abort_signal`,
  `#with_abort_signal`, `#without_abort_signal`, `#with_cancel`, `#await`, `#telemetry`,
  `#with_telemetry`, `#trace_in`), `ContextKey(T)`, `AbortSignal`, `AbortController`, `AbortError`
- `LLM::Chord::Telemetry`: `TelemetryContext`, `TelemetrySpan`, `SpanOptions`, `SpanLink`,
  `SpanStatus`, `SpanError`, `Attributes`, `Carrier`, `Metrics`, `Counter`, `UpDownCounter`,
  `Histogram`, `InstrumentOptions`, `Propagation`, `TelemetryStore`, `StoredSpan`,
  `StoredTrace`, `TraceQuery`, `TracePage`, `MetricQuery`, `StoredMetric`, `NOOP`,
  `NOOP_METRICS`, `NOOP_PROPAGATION`, `InMemoryTelemetryContext`, `RecordedSpan`,
  `RecordedMeasurement`, `.attributes`, `.render_trace`
- `LLM::Chord::Output`: `Limits`, `Retain`, `Excerpt`, `Bounded`, `Skip`, `Buffer`,
  `Progress`, `Waiter`, `Clock`, `SYSTEM_CLOCK`, `.bound`, `.sanitize`, `.character_end`,
  `.utf8_byte_length`, `PROGRESS_BYTES_PER_SECOND`
- `LLM::Chord::ChordError`, `ErrorCode`, `.chord_error?`, `.forbidden`, `.invalid`,
  `.as_chord_error`, `.run_all`
- `LLM::Chord.remote`, `.local`, `.variant`, `.method`, `.opaque`, `.host_named`,
  `.host_family`, `.resolve_host`, `.placed_on?`, `.placement_text`, `.coverage`,
  `.bind`, `.contract_from_description`, `.takes_no_args?`
- `Contract` (`RemoteContract`, `LocalContract`; `#name`, `#version`, `#input`,
  `#description`, `#fingerprint`, `#scope`, `#definition`), `RemoteDef`, `LocalDef`,
  `VariantDef`, `MethodSpec`, `OpaqueSpec`, `Member`, `Placement` (`HostNamed`,
  `HostFamily`), `Description`, `MemberDescription`, `LOCAL_VARIANT`,
  `RESERVED_MEMBERS`, `DESCRIPTION_SCHEMA`, `PLACEMENT_SCHEMA`
- `LLM::Chord::Schema.canonical_json`, `.hash64`, `.deep_equal?`, `.assert_valid`,
  `.normalize`, `.canonical_identity`, `.fits?`
- `LLM::Chord.replicated_state(initial) : MutableReplicatedState` (`#value`, `#subscribe`, `#change`, `#replace`)
- `LLM::Chord.replicated_state(source, on_error = nil) : AttachedReplicatedState` (`#value`, `#subscribe`, `#dispose`)
- `Delivery`, `DeliveryKind`, `StateListener`, `ErrorReporter`, `AggregateError`,
  `Snapshot`, `SourceFrame`, `ReplicatedStateSource`, `ReplicatedStateSourceAttachment`
- `LLM::Chord.create_host`, `Host` (`#name`, `#principal`, `#dev?`, `#ready_timeout`,
  `#code_version`, `#previous_code_version`, `#serve`, `#install`, `#load`, `#ready`,
  `#get`, `#hold`, `#root`, `#registry`, `#invalidate_principal`, `#report`, `#close`),
  `Lifetime`, `Accepts`, `Adapter`
- `ObjectScope` (`#state`, `#get`, `#resource`, `#on`, `#task`, `#derive`, `#register`,
  `#expose`), `Implementation`, `MethodFn`, `MemberValue`, `OpaqueValue`, `OpaqueBox(T)`,
  `Exposed`, `Resource(T)` (`#key`, `#value`, `#version`, `#deps`, `#exclusive?`),
  `Subscribable`
- `Ref` (`#call`, `#state`, `#opaque`, `#contract`, `#address`, `#status`, `#ready`,
  `#error`, `#variant`, `#shape`, `#on_shape`, `#on_status`, `#release`), `RefStatus`,
  `Shape`, `Ctx` (`#signal`, `#root_id`, `#code_version`, `#principal`, `#holder?`,
  `#closed?`, `#get`)
- `Readable` (`#value`, `#subscribe`, `#events`), `Cell` (`#change`, `#update`, `#replace`,
  `#schema`), `Derived`, `StateEvent`
- `Future(T)`, `LLM::Chord.race`, `.await_all`, `.not_ready`
- `Host#accept`, `#connect`, `#route`, `#connections`, `#upstream`, `#kind`; `Route`, `Upstream`,
  `LLM::Chord.upstream`, `LinkOptions`, `PeerKind`, `Role`, `Peer`, `Connection` (`#waiting`,
  `#served`, `#relayed_refs`, `#relayed_calls`), `ServedLocal`, `ServedRelay`
- `Link`, `BaseLink`, `MemoryLink`, `LLM::Chord.memory_link_pair`, `IpcChannel`, `IpcLink`,
  `LLM::Chord.ipc_link`, `WebSocketLink`, `LLM::Chord.web_socket_link`, `.accept_web_sockets`
- `Frame`, `Packed`, `Wire` (`.frame?`, `.to_error`, `.from_error`, `.encode_object`, `.decode_object`,
  `.parse`, `.encode_message`, `.decode_message`, `.inflate_message`, `FRAME_SCHEMA`),
  `PROTOCOL_VERSION`, `PACK_THRESHOLD`
- `LocalRef`, `RemoteRef`, `RemoteBinding`, `ViewReadable`, `MemberReadable`, `Ref#ended?`
- `LLM::Chord.create_host_manager`, `HostManager`, `Liveness`, `Exit`, `Driver`, `ForkDriver`,
  `LLM::Chord.fork_driver`, `Instance`, `ForkInstance`, `ControlMessage`, `ChildControl`,
  `LLM::Chord.child_control`, `.process_lock`, `LOCK_ENV`
- `Facet`, `LLM::Chord.define_facet`, `FacetApi`, `Registry(V)`, `RegistryConflict`,
  `RegistryView(V)`, `LLM::Chord.define_registry`

## Differences from chord

- Drafts are explicit `Draft` handles rather than JavaScript proxies, and
  `nil` stores JSON `null` (chord's `undefined` deletion is `Draft#delete`).
- Asynchronous listeners are opted into with `subscribe(async: true)` and run on
  fibers, instead of being detected from a returned promise. Delivery assumes
  Crystal's default single-threaded scheduler, as chord assumes one event loop.
- Promises become blocking calls on fibers: `start_span` and `trace_in` return
  the block's value, `Context#await` replaces `awaitWithContext`, and
  `Progress#mark_and_wait` returns a `Waiter`.
- Abort reasons are always exceptions; `abort("text")` wraps the text in an
  `AbortError`.
- `Output` works on UTF-8 Crystal strings. JavaScript lone surrogates have no
  equivalent, so the related upstream cases do not apply.
- Telemetry span setters follow Crystal naming: `merge_attributes` for
  `setAttributes`, `status=` for `setStatus`, and `recorded_spans` /
  `recorded_metrics` for `getSpans` / `getMetrics`. pi-telemetry's typed schema
  helpers are TypeScript type-level only and are not ported.
- Contracts carry no static types: chord's `Ref`, `ImplementationOf`, and
  `InputOf` are TypeScript type-level only. Contract construction errors are
  `ArgumentError` where chord throws `TypeError`, and `def` is `definition`.
- Schema behavior inherits the `typebox` shard's documented differences from
  TypeBox (see its README).
- Factories receive an `ObjectScope` (chord's `self`, a Crystal keyword) and
  return an `Implementation` builder. References expose members through
  `call`, `state` and `opaque` instead of a JavaScript proxy.
- `Cell#change` ignores its block's value, since Crystal draft mutators return
  values; returning a new value is `Cell#update`.
- Factories, methods, inits, tasks and listeners are ordinary Crystal code.
  Awaiting a promise becomes blocking a fiber; activations, disposals,
  listener invocations and tasks run on their own fibers. Chord's async-factory
  check has no equivalent.
- `linger` and `ready_timeout` are `Time::Span`s.
- Facets are values: Crystal cannot load code at runtime, so module paths and
  loaders do not apply (see the roadmap's reload decision).
- State versions, `migrate`, and `reload` come with reload. Until then a host
  answers a parent's `prepare` with a failed vote (`unavailable/reload_unsupported`),
  and closes the link to a child host that runs an older code version instead
  of reconciling it.
- `Link` is also the name of Crystal's top-level `@[Link]` annotation: code that
  includes `LLM::Chord` writes `LLM::Chord::Link`.
- A remote state member whose value is `undefined` reads as JSON `null`.
- Flow control counts frame sizes in UTF-8 bytes, where chord counts UTF-16
  code units; the window and caps are local accounting and never cross the wire.
- The fork driver spawns an executable with arguments (`entry`, `args`) rather
  than a Node module with `execArgv`; to run a Node child, pass `node` and the
  script.

## Development

```console
shards install
crystal spec
ameba
```

`conformance/run.sh` links Crystal and Node hosts to each other (a Node
server with a Crystal child over IPC, a Node browser on a Crystal server over a
WebSocket). It needs upstream chord's sources (`CHORD_SRC`) and Node 22 with
`typebox` 1.3.27.

Benchmarks live in `bench/` (see `bench/README.md`):

```console
crystal run bench/bench.cr --release
```

## License

MIT. See [LICENSE](LICENSE).
