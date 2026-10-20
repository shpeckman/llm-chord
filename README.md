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

Objects, hosts, links, reload, and SQLite are not ported yet; see
[ROADMAP.md](ROADMAP.md). Values are Crystal's `JSON::Any`.

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

## Development

```console
shards install
crystal spec
ameba
```

Benchmarks live in `bench/` (see `bench/README.md`):

```console
crystal run bench/bench.cr --release
```

## License

MIT. See [LICENSE](LICENSE).
