# AGENTS.md

## Overview

`llm-chord` is a Crystal port of
[`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).
It is being ported in phases tracked in `ROADMAP.md`. Phases 1–3 are done:
the delta module, replicated state, Context (values, cancellation,
telemetry), the telemetry contracts and in-memory recorder, errors, output,
schemas, and contracts follow upstream semantics. Objects, hosts, links,
reload, and SQLite are not ported yet. Values are `JSON::Any`.

The one dependency is the `typebox` shard (`path: ../typebox`), a port of
TypeBox 1.3.27's builders and `Value` functions. Schema behavior belongs
there; llm-chord only uses it.

Upstream is the specification. When behavior is in doubt, read the upstream
source and tests (`packages/chord/src`, `packages/chord/test`) and match them.

## Repository layout

```
src/llm-chord.cr                   Entry point: requires the tree, opens LLM::Chord
src/llm/chord/json.cr              deep_copy, copy_json, identical?, equal?, to_any, js_string
src/llm/chord/errors.cr            ChordError, ErrorCode, AggregateError, helpers
src/llm/chord/telemetry.cr         Telemetry contracts, store types, no-op implementations
src/llm/chord/telemetry/memory.cr  InMemoryTelemetryContext (recorder, propagation, metrics, store)
src/llm/chord/telemetry/render.cr  render_trace
src/llm/chord/context.cr           Context, ContextKey(T), AbortSignal/AbortController, await, telemetry
src/llm/chord/output.cr            bound, sanitize, Buffer (streaming UTF-8 decoder), Progress, clocks
src/llm/chord/delta/types.cr       Seg/Path/WireOp, Op hierarchy, from_tuple/to_tuple, validation, errors
src/llm/chord/delta/utf16.cr       UTF-16 code-unit counting and slicing
src/llm/chord/delta/overlap.cr     String suffix/prefix overlap helper
src/llm/chord/delta/diff.cr        diff_revisions (identity-anchored structural diff)
src/llm/chord/delta/apply.cr       apply, apply_immutable, apply_immutable_batches (copy-on-write)
src/llm/chord/delta/codec.cr       Encoder/Decoder (path interning + arity omission)
src/llm/chord/delta/draft.cr       Draft: revocable copy-on-write handles
src/llm/chord/delta/tracker.cr     Overlay, Change, Prepared, Tracker, track
src/llm/chord/state.cr             replicated_state: publisher, subscribers, mutable and attached state
src/llm/chord/schema.cr            canonical_json, hash64, normalize, canonical_identity, assert_valid, fits?
src/llm/chord/contract.cr          method/opaque, placement, remote/local, Description, coverage, bind
spec/                              Crystal specs, largely translated from upstream tests
bench/                             Release-mode micro-benchmarks
ROADMAP.md                         Porting phases and settled design decisions
.ameba.yml                         Ameba linter config
```

## Build / test / spec

```console
shards install
crystal spec
ameba
crystal run bench/bench.cr --release
```

`ameba` reads `.ameba.yml`; three rules are disabled there:
`Naming/QueryBoolMethods`, `Lint/NotNil`, and `Metrics/CyclomaticComplexity`.
The specs never hit the network.

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm/chord/delta/diff.cr`. No other comments in code.
- Compiler-friendly, performance-focused, idiomatic Crystal; data-driven design.
- The usage-facing API must be ergonomic.
- Prevent shotgun surgery: a behavior change should touch one cohesive spot.
- Never use `out` as an identifier — it is a reserved keyword.
- Never edit the `version` field in `shard.yml`.
- Keep `README.md` (usage and public API), this file, and `ROADMAP.md` in sync
  with the code.

## Conventions specific to this codebase

- Paths are `Seg = String | Int32` with `Path = Array(Seg)`. Inside specs and
  any file that includes `LLM::Chord::Delta`, write `Delta::Path`: a bare
  `Path` resolves to the standard library's `::Path`.
- JSON integers are `Int64`; array indices and counts are `Int32`. Counts read
  from JSON clamp to `Int32::MAX`, matching JavaScript's splice clamping.
- Ops are a sealed struct hierarchy. `Op::Targeted` carries `path` and
  `arguments`; `to_tuple` and the encoder both build from `arguments`, so a new
  field changes one method. Constructors validate, so an `Op` value is always
  well formed.
- Identity matters. `Json.identical?` is container identity (`same?`) or
  primitive equality, matching JavaScript `===`; `Json.equal?` is deep equality
  ignoring key order. The diff uses identity for anchors and permutations,
  exactly like upstream, so structural sharing between revisions must be kept.
- The tracker is copy-on-write. An `Overlay` per change owns the containers it
  copied (by `object_id`, pinned to prevent reuse) and maps each copied source
  to its copy, so every handle resolves to the latest copy. `prepare` diffs
  the base against the draft root, then materializes `prepared.value` with
  `apply_immutable(base, ops)`, so the candidate is exactly what replicas
  compute. Overlays are registered as `WeakRef`s and invalidated on adoption.
- `Draft` handles keep their parent handle and key. On first write a handle
  copies its container and relinks it into the parent by identity; if the
  element is gone, the copy is orphaned and the write is ignored.
- Replicated state delivery mirrors upstream's `StateSubscriber`: a
  per-subscription queue of 100 with newest-wins overflow, the running callback
  excluded. Async subscriptions shift the next frame before spawning, which is
  the equivalent of a JavaScript async listener starting synchronously.
  Listener errors are always reported, never raised into the publisher.
- Telemetry lives in `LLM::Chord::Telemetry` and mirrors the subset of
  `@earendil-works/pi-telemetry` (`packages/telemetry`) that chord uses. The
  in-memory recorder resolves carriers by concrete type
  (`Telemetry.carrier_of`), the analogue of upstream's module-level WeakMap, so
  links work across recorders.
- Upstream promises map to blocking calls on fibers. Work that upstream starts
  without awaiting (an async listener, a progress `write`, `awaitWithContext`)
  is spawned; results come back through channels.
- Compiler quirk: a method that captures a block (`&block : ...`) and also
  contains a proc literal (`-> { }`) can fail with "read before assignment" for
  the block variable. Keep the proc literal in a separate private method, as
  `AbortSignal#remover` and `SystemClock#disarmer` do.
- `Output` counts bytes on UTF-8 strings; its byte decoder follows the WHATWG
  UTF-8 decoder exactly, including how many U+FFFD an invalid sequence yields.
- The differential harness used during Phase 1 generated cases with upstream's
  `diffRevisions` and `track` under Node and compared op batches and values;
  re-run something similar when changing `diff.cr` or the tracker. Phase 2 did
  the same for `Output.bound`, `sanitize`, and `Buffer` snapshots, including
  byte chunks with invalid UTF-8, BOMs, and skips.
- Phase 3 ran upstream's `src/contract.ts` and `src/schema.ts` directly under
  `node --experimental-strip-types` (with `typebox` linked into the package's
  `node_modules`) on generated contracts, and compared descriptions,
  fingerprints, `hash64`, normalized inputs and identities, `coverage`, and
  `fits`. Re-run it when changing `schema.cr`, `contract.cr`, or the typebox
  shard.
- Contracts keep descriptions as raw JSON (`Description#json`) so a received
  token fingerprints exactly as sent; typed accessors read from it. Build
  descriptions only in `remote` / `local`, in upstream's key order.
- `bind` is generic over the adapter type (`Hash(Int32, A)`), so Phase 4
  decides what an adapter is without touching contracts.
