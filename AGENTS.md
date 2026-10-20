# AGENTS.md

## Overview

`llm-chord` is a Crystal port of
[`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).
It is being ported in phases tracked in `ROADMAP.md`. Phase 1 is done: the delta module, Context
values, and replicated state now follow upstream semantics. Contracts,
objects, hosts, links, reload, output, SQLite, and telemetry are not ported
yet. The shard has no dependencies; values are `JSON::Any`.

Upstream is the specification. When behavior is in doubt, read the upstream
source and tests (`packages/chord/src`, `packages/chord/test`) and match them.

## Repository layout

```
src/llm-chord.cr                   Entry point: requires the tree, opens LLM::Chord
src/llm/chord/json.cr              deep_copy, copy_json, identical?, equal?, to_any, js_string
src/llm/chord/context.cr           Context, ContextKey(T), BACKGROUND/TODO, with_value
src/llm/chord/delta/types.cr       Seg/Path/WireOp, Op hierarchy, from_tuple/to_tuple, validation, errors
src/llm/chord/delta/utf16.cr       UTF-16 code-unit counting and slicing
src/llm/chord/delta/overlap.cr     String suffix/prefix overlap helper
src/llm/chord/delta/diff.cr        diff_revisions (identity-anchored structural diff)
src/llm/chord/delta/apply.cr       apply, apply_immutable, apply_immutable_batches (copy-on-write)
src/llm/chord/delta/codec.cr       Encoder/Decoder (path interning + arity omission)
src/llm/chord/delta/draft.cr       Draft: revocable copy-on-write handles
src/llm/chord/delta/tracker.cr     Overlay, Change, Prepared, Tracker, track
src/llm/chord/state.cr             replicated_state: publisher, subscribers, mutable and attached state
spec/                              Crystal specs, largely translated from upstream tests
bench/                             Release-mode micro-benchmarks
ROADMAP.md                         Porting phases and open decisions
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
- The differential harness used during Phase 1 generated cases with upstream's
  `diffRevisions` and `track` under Node and compared op batches and values;
  re-run something similar when changing `diff.cr` or the tracker.
