# llm-chord

Transactional JSON revision tracking and operation batches, ported from
`@earendil-works/chord/delta` into idiomatic Crystal.

The delta module lets you hold a JSON value as an immutable current revision,
open a mutable change over it, and settle that change into an exact operation
batch (`r`/`s`/`d`/`a`/`t`/`p`/`m`) that replicas can apply. Values are
Crystal's `JSON::Any`.

## Requirements

- Crystal `>= 1.21.0`

## Installation

Add the shard to your `shard.yml`:

```yaml
dependencies:
  llm-chord:
    github: shpeckman/llm-chord
```

Then `shards install`. In your code:

```crystal
require "llm-chord"
```

## Quick start

### Tracking

```crystal
tracker = LLM::Chord::Delta.track(JSON.parse(%({"output":"","entries":[]})))

change = tracker.begin_change
change.state["output"] = "done\n"
change.state["entries"] << {"id" => 1}
prepared = change.prepare

tracker.adopt(prepared)
tracker.value      # => {"output":"done\n","entries":[{"id":1}]}
tracker.revision   # => 1
```

`begin_change` deep-copies the current revision into a mutable draft, so
`tracker.value` is never mutated. `prepare` computes the operation batch; a
change with no net effect yields an empty batch. Adopting one change makes
other open or prepared changes stale.

`prepare_replace` replaces the whole root:

```crystal
prepared = tracker.prepare_replace(JSON.parse(%({"fresh":true})))
tracker.adopt(prepared)
```

### Diffing

```crystal
ops = LLM::Chord::Delta.diff_revisions(
  JSON.parse(%({"a":"x","b":1})),
  JSON.parse(%({"a":"xy","c":2})),
)
```

### Applying

```crystal
result = LLM::Chord::Delta.apply_immutable(base, ops)            # new value, base untouched
result = LLM::Chord::Delta.apply(base, ops)                      # mutates base in place
result = LLM::Chord::Delta.apply_immutable_batches(base, [b1, b2])
```

### Wire codec

The codec compresses a batch with path interning (a path's second use becomes
an id) and arity omission (a repeated path is dropped):

```crystal
wire = LLM::Chord::Delta::Encoder.new.encode(ops)
ops  = LLM::Chord::Delta::Decoder.new.decode(wire)
```

### Replicated state

Observable immutable state over the tracker:

```crystal
state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})))

unsub = state.subscribe do |value, delivery|
  # delivery.kind : Hydrate | Update, delivery.sequence : Int32
  puts value.to_json
end

state.change { |draft| draft["n"] = 1 }       # atomic; publishes on non-noop
state.replace(JSON.parse(%({"fresh":true})))  # atomic whole-root replace
unsub.call
```

`replicated_state(source)` attaches a publication-only view to an external
authoritative stream (`ReplicatedStateSource`).

Pass `async: true` to deliver to each subscriber on its own fiber instead of
synchronously; listeners then never block the publishing fiber (per-subscriber
backpressure is a bounded 100-frame channel):

```crystal
state = LLM::Chord.replicated_state(JSON.parse(%({"n":0})), async: true)
```

## Operations

| Verb | Struct          | Meaning                                      |
|------|-----------------|----------------------------------------------|
| `r`  | `Op::Replace`   | Replace the whole value.                     |
| `s`  | `Op::Set`       | Set an object property or array element.     |
| `d`  | `Op::Delete`    | Delete an object property or array element.  |
| `a`  | `Op::Append`    | Append text to a string.                     |
| `t`  | `Op::Truncate`  | Remove `count` characters from a string's front. |
| `p`  | `Op::Splice`    | Splice an array.                             |
| `m`  | `Op::Move`      | Reorder an array: `new[i] = old[permutation[i]]`. |

Batches are exact but not canonical: the same change may be described by
different tuples, and large edits may fold into a whole-root `r`.

## Public API reference

- `LLM::Chord::Delta.track(initial : JSON::Any) : Tracker`
- `Tracker#value`, `#revision`, `#begin_change`, `#prepare_replace`, `#adopt`
- `Change#state` (`Draft`), `#prepare`, `#abort`
- `Prepared#base`, `#value`, `#ops`, `#base_revision`, `#abort`
- `LLM::Chord::Delta.diff_revisions(before, after) : Array(Op)`
- `LLM::Chord::Delta.apply(target, ops)`, `.apply_immutable(target, ops)`,
  `.apply_immutable_batches(target, batches)`, `.apply_immutable_shared(target, ops)`,
  `.apply_immutable_batches_shared(target, batches)`
- `LLM::Chord::Delta::Encoder#encode(ops)`, `LLM::Chord::Delta::Decoder#decode(wire)`
- `LLM::Chord::Delta.overlap(a, b, scan, probe = 64, max_candidates = 8)`
- `LLM::Chord::Json.deep_copy`, `LLM::Chord::Json.container?`, `LLM::Chord::Json.valid?`,
  `LLM::Chord::Json.strict?`, `LLM::Chord::Json.validate!`, `LLM::Chord::Json.to_any`,
  `LLM::Chord::Json.to_struct(T, value)`, `LLM::Chord::Json.from_struct(value)`
- Types: `Seg = String | Int32`, `Path = Array(Seg)`, `Op` (abstract) with
  `Op::Replace`, `Op::Set`, `Op::Delete`, `Op::Append`, `Op::Truncate`,
  `Op::Splice`, `Op::Move`; `Draft` (mutable draft wrapper over `JSON::Any`)
- `Draft` (`Change#state`): `[]`, `[]?`, `[]=`, `<<`, `push`, `pop`, `shift`,
  `unshift`, `splice`, `delete_at`, `delete`, `size`, `empty?`, `reverse!`,
  `sort!`, typed accessors (`string?`, `int`, `float`, `bool`, `array`,
  `object`), and `as_s/as_i/as_f/as_bool/as_a/as_h/null?`
- Errors: `LLM::Chord::Delta::UnsafePathError`, `LLM::Chord::Delta::PathError`
- `LLM::Chord.replicated_state(initial, on_error = nil, async = false)` → `MutableReplicatedState`
  (`#value`, `#subscribe`, `#change`, `#replace`)
- `LLM::Chord.replicated_state(source, on_error = nil, async = false)` → `AttachedReplicatedState`
  (`#value`, `#subscribe`, `#activate`, `#dispose`)
- `LLM::Chord::Cell.from(state, &compute)` → `Cell` (`#value`, `#subscribe`)
- `LLM::Chord::Context` (`#provide`, `#require`, `#fetch`)
- `LLM::Chord::Delivery` (`kind`, `sequence`), `LLM::Chord::DeliveryKind`,
  `LLM::Chord::ReplicatedStateSource`, `LLM::Chord::ReplicatedStateSourceAttachment`,
  `LLM::Chord::Snapshot`, `LLM::Chord::SourceFrame`

## Development

Run the specs and the linter:

```console
shards install
crystal spec
ameba
```

## Benchmarks

Micro-benchmarks for the delta hot paths live in `bench/` (see `bench/README.md`).
Run them in release mode:

```console
crystal run bench/bench.cr --release
```

## License

MIT. See [LICENSE](LICENSE).
