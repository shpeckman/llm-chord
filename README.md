# llm-chord

A Crystal port of [`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).

The port currently covers chord's foundation layer:

- `LLM::Chord::Delta` — `@earendil-works/chord/delta`: transactional JSON
  revision tracking, structural diff, immutable apply, and the wire codec.
- `LLM::Chord.replicated_state` — chord's observable replicated state, either
  authoritative and mutable or attached to an external revision source.
- `LLM::Chord::Context` — explicit invocation-scoped values (`ContextKey`,
  `with_value`, `BACKGROUND`, `TODO`).

Contracts, objects, hosts, links, reload, output, SQLite, and telemetry are not
ported yet; see [ROADMAP.md](ROADMAP.md). Values are Crystal's `JSON::Any`.

## Requirements

- Crystal `>= 1.21.0`

## Installation

```yaml
dependencies:
  llm-chord:
    github: shpeckman/llm-chord
```

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

Contexts are immutable; `with_value` derives a child. Keys match by identity.

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
- `LLM::Chord::Context` (`BACKGROUND`, `TODO`, `#value`, `#with_value`), `LLM::Chord::ContextKey(T)`
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
