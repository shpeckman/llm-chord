# llm-chord

A Crystal port of [`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).

The port currently covers chord's foundation layer:

- `LLM::Chord::Delta` — `@earendil-works/chord/delta`: transactional JSON
  revision tracking, structural diff, immutable apply, and the wire codec.
- `LLM::Chord.replicated_state` — chord's observable replicated state, either
  authoritative and mutable or attached to an external revision source.
- `LLM::Chord::Context` — `@earendil-works/chord/context`: explicit
  invocation-scoped values, cancellation, and telemetry spans. Telemetry comes
  from the [`llm-telemetry`](https://github.com/shpeckman/llm-telemetry) shard
  (`LLM::Telemetry`).
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
- Reload — chord's hot reload, in process: code versions with the two-version
  rule and retirement, state versions and `migrate`, prepare in recording mode,
  the gate with leases and grandfathered roots, exclusive resources, the
  synchronous commit, and cluster reloads across hosts (prepare, vote, commit,
  abort, retire; fencing and reconciliation of children that connect behind).
- `LLM::Chord::Sqlite` — `@earendil-works/chord/sqlite` and `/sqlite/node`:
  a portable SQLite database interface, schema-prefix validation, atomic
  migrations, and an adapter on `crystal-sqlite3`.
- `LLM::Chord::SqliteTelemetry` — `@earendil-works/chord/telemetry-sqlite`: a
  buffered SQLite telemetry recorder and `TelemetryStore`.

Values are Crystal's `JSON::Any`. Chord's Cloudflare Durable Object adapter
(`/sqlite/cloudflare`) has no Crystal target and is not ported.

## Requirements

- Crystal `>= 1.21.0`

## Installation

```yaml
dependencies:
  llm-chord:
    github: shpeckman/llm-chord
```

llm-chord depends on the `typebox` shard (`github: shpeckman/typebox`), the
`llm-telemetry` shard (`github: shpeckman/llm-telemetry`) and `crystal-sqlite3`
(`github: crystal-lang/crystal-sqlite3`, `~> 0.24.0`, with `crystal-db`
0.15) in its `shard.yml`.

Then `shards install`, and in your code:

```crystal
require "llm-chord"
```

The SQLite modules have their own entry points, so `require "llm-chord"` alone
never links `libsqlite3`:

```crystal
require "llm-chord/sqlite"            # LLM::Chord::Sqlite
require "llm-chord/telemetry-sqlite"  # LLM::Chord::SqliteTelemetry (also requires llm-chord/sqlite)
```

The SQLite modules need the SQLite 3 library and headers (3.37 or newer, for
`STRICT` tables and the JSON functions).

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
recorder = LLM::Telemetry::InMemoryTelemetryContext.new
recorder.start_span(LLM::Telemetry::SpanOptions.new("app.request")) do |span|
  context = LLM::Chord::Context::BACKGROUND.with_telemetry(span)
  context.trace_in("app.load") do |child|
    child.telemetry.add_event("cache.miss")
    child.trace_in("app.read") { |nested| read_account(nested) }
  end
end
```

`context.telemetry` is the context's span, or `LLM::Telemetry::NOOP` when none
was set. `trace_in(options)` (or `trace_in(name)`) runs the block in a child
span and passes a derived context; the block's value and exceptions pass
through. There is no ambient current span.

Spans, metrics, propagation, the in-memory recorder, trace queries and
`render_trace` are documented in the `llm-telemetry` shard's README.

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
| `task_stop_deadline` | How long a reload waits for an object's aborted tasks to finish before starting their replacements anyway (reported). Default 5 s. |
| `loader` | `FacetLoader` (`Proc(Array(String), Array(Facet))`): resolves module names to facets for `load`, `reload` and the `prepare` frames of a cluster reload. |
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
- `install(facet, await_host_objects: true)`, `load(plugins, await_host_objects: true)`
  and `ready` start and await host-lifetime objects; `load` installs every
  facet before awaiting any. `plugins` are facets or module names resolved by
  the `loader`. A facet is installed once; later versions come with `reload`.
- `reload(plugins, remove:, ...)` replaces facets in place (see
  [Reload](#reload)). `code_version` and `previous_code_version` tell which
  code versions the host retains.
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
| `scope.state(name, schema, initial, version: 1, migrate: nil)` | A cell with an initial value (always validated). A reload keeps the cell and its value by name (`initial` is ignored); a raised `version` runs `migrate` (`Proc(JSON::Any, Int32, T)`: old value, its version). |
| `scope.state(name, schema, version: 1, migrate: nil) { \|ctx\| value }` | A cell filled by an init that runs in its own root after the object's resources are open and its references live, before the object goes live. A kept cell does not run it again. |
| `scope.get(type, input = nil, principal: nil)` | A reference the object holds for its lifetime, kept across reloads by address. Holding cycles raise `invalid/cycle`. |
| `scope.resource(name, version:, deps:, exclusive:, close:) { \|signal\| value }` | Opened before the object goes live (after its `deps`, references or resources), closed in reverse order after it is disposed. `value` raises `not_ready` while any factory runs. A reload keeps it unless `version`, `deps`, `exclusive` or its value type change; a kept resource adopts the new `open` and `close`. |
| `scope.on(name, source) { \|event, ctx\| }` | A listener on a readable (current value, then every new one) or a `Subscribable`. `on(name, resource)` listens to the resource's value; `on(name, resource, selector)` to `selector.call(value)`. Each event runs in a fresh root. A reload keeps the subscription while its source and selector (the same proc literal) are unchanged and swaps the handler. |
| `scope.task { \|ctx\| }` | Long-running work of the live object, aborted at disposal. Calls made with its ctx start fresh roots. A reload restarts it with the new code once the old run finished. |
| `scope.derive(sources) { \|values\| value }` | A synchronous projection of readables, recomputed atomically with object writes and on publication of other sources. Every reload makes a new one. |
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
when this run of the facet is no longer installed: a committed reload replaced
or removed it, the reload that loaded it aborted, or the host closed).
`define_registry(V, name, conflict: :error)` refuses two objects registering
one key; `:last` keeps the later one. `RegistryView` has `table(ctx = nil)`,
`get(key, ctx = nil)` and `subscribe { |table, code_version| }`; tables are
kept per code version (a ctx reads the table of its code version) and keep
registration order.

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

## Reload

A reload replaces facets while the host runs. Objects survive it: their cells,
open resources, references and listener subscriptions are found again by name
in the new factory's run. Facets are values compiled into the program, so a
reload switches between facets the binary contains; shipping new Crystal code
is a new binary (`HostManager#replace`), which a parent reconciles when it
connects.

```crystal
facet = ->(greeting : String) do
  C.define_facet("greeter") do |api|
    api.serve(Greeter) do |_input, _principal, scope|
      count = scope.state("count", T.object({n: T.number}), {n: 0})
      C::Implementation.new.state("count", count).method("greet") { |name| "#{greeting} #{name}" }
    end
  end
end

host.install(facet.call("hello"))
report = host.reload([facet.call("hi")])  # compatible: no gate, nothing waits
report.code_version                       # the new code version; report.previous was current
```

`reload(plugins = [] of Facet, remove:, gate_deadline:, retire_deadline:,
remote:, remote_remove:, vote_deadline:)` returns a `ReloadReport`
(`code_version`, `previous`, `changed` and `removed` type names, `prepared` and
`gated` object addresses, and `children`: each participating child's report).
Reloads are serialized (`unavailable/reload_running`); a failed one raises its
cause's code with the message `reload aborted: ...` and changes nothing.

- **Prepare.** For each live object of a changed type, the new factory runs in
  recording mode: cells are readable and writes raise `invalid/read_only`;
  listeners, tasks and registrations are recorded; new non-exclusive resources
  open. A cell whose schema changed without a raised `version` is refused, as
  is a lowered version. Contracts are checked: the same contract version must
  cover the old description (a forgotten bump is `contract_mismatch`), and
  every surviving consumer and every facet's `uses` must bind, directly or
  through `accepts`.
- **Gate.** Only objects with a raised cell version or a replaced exclusive
  resource are gated. Roots that already called them are grandfathered; other
  old roots, and new objects of changed types, get `upgrade_conflict`
  (retryable). The gate waits for grandfathered roots at most `gate_deadline`
  (5 s; `aborted/gate_deadline` names the blocking roots), swaps exclusive
  resources, and runs `migrate` into private copies, validated against every
  schema that will apply.
- **Commit.** One synchronous step installs the new code version: implementations,
  migrated values (subscribers see a reset), registry tables, new derivations,
  rebound listeners and restarted tasks; references see a shape push, and
  browser references that no longer bind become `gone` with `upgrade_required`.
- **Two-version rule.** A host keeps the current and the previous code version.
  A call carrying a code version the host no longer has is `superseded`
  (retryable). The previous code version retires when its last root ended (and,
  on a child, its parent retired it). The next reload waits for that at most
  `retire_deadline` (5 s), then aborts those roots, gives them a second, and
  closes what only that code version declared.
- **Clusters.** A host with child hosts (or given `remote:`) coordinates: it
  sends `prepare` with the module names `remote` gives each child by host-name
  prefix (longest wins), collects votes within `vote_deadline` (gate + retire
  deadlines + 5 s), commits itself, then sends `commit` before anything of the
  new code version can reach a child. A child cannot reload on its own
  (`unavailable/not_coordinator`). A child that connects behind is fenced (its
  roots' calls are admitted in the parent's code version) and reconciled by a
  reload of the modules earlier cluster reloads gave it.

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

## SQLite

```crystal
require "llm-chord/sqlite"

S = LLM::Chord::Sqlite

db = S.open_database("data/state.db")   # or ":memory:"
S.apply_migrations(db, [
  S::Migration.new(1, ["CREATE TABLE notes (body TEXT)"]),
  S::Migration.new(2, ["ALTER TABLE notes ADD COLUMN title TEXT"]),
], table: "notes_schema")

db.run("INSERT INTO notes (body, title) VALUES (?, ?)", "hello", nil)
db.get("SELECT body FROM notes")         # => {"body" => "hello"}
db.all("SELECT * FROM notes")            # => [{"body" => "hello", "title" => nil}]
db.transaction do |tx|
  tx.run("UPDATE notes SET title = ?", "greeting")
end
db.close
```

`Sqlite::Database` is chord's portable `SqliteDatabase` facade:

| Member | Meaning |
| --- | --- |
| `exec(sql)` | Runs SQL text without bindings; it may contain several statements. |
| `run(sql, *params)` | Runs one statement with positional bindings. |
| `get(sql, *params)` | The first row (`Row?`). |
| `all(sql, *params)` | Every row (`Array(Row)`). |
| `transaction { \|tx\| ... }` | Runs the block in a transaction and returns its value. All its work must use `tx`, which raises `Sqlite::Error` ("SQLite transaction handle is no longer active") once the block returns. |
| `close` | Closes the database; idempotent. |

- Values are `Sqlite::Value` (`Int64 | Float64 | String | Bytes | Nil`);
  `run`, `get` and `all` also take other `Int` and `Float` values. A row is a
  `Sqlite::Row` (`Hash(String, Value)`) keyed by column name.
- Bindings are values, never interpolated SQL: prepared statements are cached
  by SQL text on the connection.
- A failing block rolls the transaction back and raises the block's own
  exception. If the rollback fails too, it raises an `AggregateError` instead,
  so a caller cannot mistake the error for a guaranteed rollback.
- `Executor` is the interface of a database and a transaction handle. An
  adapter implements `exec`, `run_values`, `get_values` and `all_values`
  (taking `Array(Value)`); `run`, `get` and `all` convert and delegate.

`Sqlite.open_database(path, wal_autocheckpoint_pages: 1_000, busy_timeout_ms: 5_000)`
returns a `Sqlite3Database`: one `crystal-sqlite3` connection (not a pool, so a
`:memory:` database is one database). It creates the file's directory, sets
`journal_mode = WAL`, `synchronous = NORMAL`, the WAL auto-checkpoint
threshold (`0` disables it) and the time SQLite waits for a competing lock.

- Operations run strictly in call order, on any fiber: a transaction holds the
  queue until its block returns, and calls made meanwhile wait behind it, so
  they neither see its uncommitted rows nor join its rollback. Calling the
  database itself (not `tx`) from inside a transaction block waits for that
  transaction, which never ends.
- Transactions begin with `BEGIN IMMEDIATE`. `close` checkpoints the WAL with
  `TRUNCATE`; operations on a closed database raise `Sqlite::Error`.
- SQL errors raise `SQLite3::Exception`.

`Sqlite.apply_migrations(db, migrations, table:)` applies every pending
migration atomically: the version table's creation and every pending
migration commit or roll back together. Versions must be `1, 2, 3, ...`; the
table (`singleton`, `version`, `STRICT`) records the version reached, a database
newer than the last migration raises, and independent tables keep independent
histories. `Sqlite.validate_schema_prefix(prefix)` accepts identifiers
(`[A-Za-z_][A-Za-z0-9_]*`) that do not start with `sqlite_` in any case; the
migration table name is validated before any SQL runs. Both raise
`Sqlite::Error` with chord's messages.

## SQLite telemetry

```crystal
require "llm-chord/telemetry-sqlite"

db = LLM::Chord::Sqlite.open_database("data/telemetry.db")
telemetry = LLM::Chord.create_sqlite_telemetry(db)

telemetry.start_span(LLM::Telemetry::SpanOptions.new("request")) do |span|
  span.add_event("loaded")
  telemetry.counter("requests").add(1, LLM::Telemetry.attributes(route: "/"))
end

telemetry.flush
telemetry.find_traces(LLM::Telemetry::TraceQuery.new(name: "request"))
telemetry.close   # stops recording and drains; the database stays open
db.close
```

`create_sqlite_telemetry(db, retention: 7.days, max_queued_spans: 10_000, clock: LLM::Telemetry::SYSTEM_CLOCK)`
migrates its tables (`telemetry_spans`, `telemetry_metrics`, versioned in
`telemetry_schema`) and returns a `SqliteTelemetry`: an
`LLM::Telemetry::TelemetryContext` that is also its own `Metrics`,
`Propagation` and `TelemetryStore`.

- Recording never runs SQL. Only settled spans are stored, with their
  attributes, events (time relative to the span's start), links and status.
  Metrics aggregate `count`, `sum`, `min` and `max` per series (name, kind,
  unit, attributes) and ten-second interval; descriptions and histogram
  boundaries are not kept.
- A flush runs every second. `flush` persists settled spans and completed
  intervals; `close` also writes partial intervals. Each flush is one
  transaction, which also deletes rows older than `retention`. Flushes are
  serialized, and concurrent `close` calls share one drain.
- `max_queued_spans` bounds the settled spans awaiting commit, including the
  batch being written, and separately the pending metric interval/series pairs.
  What does not fit is counted in `dropped_spans` and `dropped_measurements`.
- A write failure stops recording for good: `flush` and `close` raise that same
  exception from then on, without retrying.
- After `close`, recording is inert (spans still run their blocks) and the
  store still reads committed rows.
- `inject`/`extract` carry the span identity under `pi-sqlite-span` and
  `pi-sqlite-trace`, so a trace continues across processes and recorders. Span
  ids are `<recorder UUID>:<sequence>`; a root span's trace id is its own id.
- Reads see committed rows only; `flush` first to include new spans.
  `find_traces` pages with an opaque cursor in two queries per page, filtering
  by the first span's name and start, any error, and attributes all present
  on one span (a boolean never equals a number).
- Stored JSON (attributes, events, links, status and the series key) is
  written exactly as `JSON.stringify` writes it, so Crystal and Node recorders
  can share one database file and merge aggregates. Consequently a whole
  `Float64` attribute such as `2.0` is stored as `2` and reads back as
  `Int64`.
- `clock` (an `LLM::Telemetry::Clock`) provides the wall time, the monotonic
  time and the one-second timer; pass an `LLM::Telemetry::Testing::ManualClock`
  to control them in tests.

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
  `#reload`, `Lifetime`, `Accepts`, `Adapter`, `CodeVersion`
- `ReloadReport` (`#code_version`, `#previous`, `#changed`, `#removed`, `#prepared`, `#gated`,
  `#children`), `ReloadOptions`, `Migration`, `FacetLoader`, `DEFAULT_GATE_DEADLINE`,
  `DEFAULT_RETIRE_DEADLINE`
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
- `LLM::Chord::Schema.stringify` (insertion-order `JSON.stringify`)
- `LLM::Chord::Sqlite` (`require "llm-chord/sqlite"`): `Value`, `Row`, `Error`, `Executor`
  (`#exec`, `#run`, `#get`, `#all`, `#run_values`, `#get_values`, `#all_values`), `Database`
  (`#transaction`, `#close`), `Migration`, `.apply_migrations`, `.validate_schema_prefix`,
  `.open_database`, `Sqlite3Database` (`#closed?`), `Sqlite3Executor`, `Sqlite3Transaction`,
  `SerialQueue`, `DEFAULT_WAL_AUTOCHECKPOINT_PAGES`, `DEFAULT_BUSY_TIMEOUT_MS`
- `LLM::Chord.create_sqlite_telemetry` (`require "llm-chord/telemetry-sqlite"`), `SqliteTelemetry`
  (`#start_span`, `#counter`, `#up_down_counter`, `#histogram`, `#inject`, `#extract`, `#get_trace`,
  `#find_traces`, `#find_metrics`, `#flush`, `#close`, `#dropped_spans`, `#dropped_measurements`,
  `#stopped?`; `.get_trace`, `.find_traces`, `.find_metrics` over a database; `SPAN_KEY`,
  `TRACE_KEY`, `INTERVAL_MS`, `FLUSH_INTERVAL`, `DEFAULT_RETENTION`, `DEFAULT_MAX_QUEUED_SPANS`,
  `MIGRATIONS`)

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
- Telemetry is the separate `llm-telemetry` shard (`LLM::Telemetry`). Its span
  setters follow Crystal naming: `merge_attributes` for `setAttributes`,
  `status=` for `setStatus`, and `recorded_spans` / `recorded_metrics` for
  `getSpans` / `getMetrics`. pi-telemetry's typed schema helpers are
  TypeScript type-level only and are not ported.
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
- Facets are values: Crystal cannot load code at runtime, so a `FacetLoader`
  maps module names to facets compiled into the program, and a reload switches
  between them (see the roadmap's reload decision). Upstream's Node loader is
  not ported.
- A listener's selector counts as unchanged when it is the same proc literal
  (`Proc#pointer`), where chord compares the function's source text.
- A kept resource must also keep its value type: a resource whose block now
  returns another type is a new resource.
- Upstream's generation GC tests rely on V8's `FinalizationRegistry`; Crystal's
  conservative collector cannot assert collection, so they are not ported. A
  retired code version's implementations, declarations and cached adapter views
  are dropped all the same.
- `Link` is also the name of Crystal's top-level `@[Link]` annotation: code that
  includes `LLM::Chord` writes `LLM::Chord::Link`.
- A remote state member whose value is `undefined` reads as JSON `null`.
- Flow control counts frame sizes in UTF-8 bytes, where chord counts UTF-16
  code units; the window and caps are local accounting and never cross the wire.
- The fork driver spawns an executable with arguments (`entry`, `args`) rather
  than a Node module with `execArgv`; to run a Node child, pass `node` and the
  script.
- SQLite operations block the calling fiber instead of returning promises, and
  rows are `Hash(String, Value)` rather than typed objects (`get<T>`). The
  adapter is `crystal-sqlite3` where chord uses `node:sqlite`; its
  `open_database` is chord's `openNodeSqliteDatabase`, with `busy_timeout_ms`
  and `wal_autocheckpoint_pages` for `busyTimeoutMs` and
  `walAutoCheckpointPages`. A closed database raises `Sqlite::Error`.
- `create_sqlite_telemetry` takes `retention` as a `Time::Span` (chord's
  `retentionMs`) and an injectable `clock`, where chord reads `Date.now`,
  `performance.now` and `setInterval`. A span that raised gets the exception's
  class name as its error name.

## Development

```console
shards install
crystal spec
ameba
```

The SQLite specs use in-memory databases (and one temporary file). The
SQLite telemetry specs run `llm-telemetry`'s adapter and store conformance
suites (`require "llm-telemetry/testing"`) against `SqliteTelemetry`.

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