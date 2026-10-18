# AGENTS.md

## Overview

`llm-chord` is a Crystal port of the standalone `@earendil-works/chord/delta`
module: transactional JSON revision tracking plus exact operation batches for
ordered replicas. It is self-contained (no dependencies) and exposes one
namespace, `LLM::Chord::Delta`, over Crystal's `JSON::Any`.

## Repository layout

```
src/llm-chord.cr                   Entry point: requires the tree, opens LLM::Chord
src/llm/chord/json.cr              deep_copy, container?, valid? over JSON::Any
src/llm/chord/delta/types.cr       Seg/Path, the Op hierarchy, errors, path safety
src/llm/chord/delta/overlap.cr     String suffix/prefix overlap helper
src/llm/chord/delta/diff.cr        diff_revisions (structural JSON diff)
src/llm/chord/delta/apply.cr       apply, apply_immutable, apply_immutable_batches
src/llm/chord/delta/codec.cr       Encoder/Decoder (path interning + arity omission)
src/llm/chord/delta/draft.cr       Draft wrapper (ergonomic mutation over JSON::Any)
src/llm/chord/delta/tracker.cr     track, Tracker, Change, Prepared
spec/                              Crystal specs (one file per unit)
.ameba.yml                         Ameba linter config (disabled rules)
```

## Build / test / spec

There are no build targets. Install dependencies and run the specs and linter:

```console
shards install
crystal spec
ameba
```

`ameba` reads `.ameba.yml`; three rules are intentionally disabled there —
`Naming/QueryBoolMethods` (would rename `Bool` getters to `?` and break the
public API), `Lint/NotNil` (`not_nil!` is used intentionally), and
`Metrics/CyclomaticComplexity`. The specs never hit the network.

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm/chord/delta/diff.cr`. No other comments in code.
- The usage-facing API must be ergonomic: a small number of entry points with
  sensible defaults.
- Prevent shotgun surgery: a behavior change should touch one cohesive spot.
- Never use `out` as an identifier — it is a reserved keyword.
- Never edit the `version` field in `shard.yml`.
- Match existing naming and structural idioms rather than importing new
  conventions.

## Conventions specific to this codebase

- Values are `JSON::Any`; paths are `Seg = String | Int32` with `Path = Array(Seg)`.
  Array indices are `Int32`; JSON integers are `Int64` (converted at the wire
  boundary in the codec).
  `Op` struct hierarchy (`Op::Replace`, `Op::Set`, `Op::Delete`, `Op::Append`,
  `Op::Truncate`, `Op::Splice`, `Op::Move`). The wire codec is the only place
  that knows the JSON tuple form.
- The mutable draft is implemented as clone + diff, not chord's JS Proxy:
  `begin_change` deep-copies the base, and `prepare` runs `diff_revisions`
  against it. This reproduces the observable contract (value, op vocabulary,
  no-op/stale/adopt semantics) with a simpler, Crystal-idiomatic design; the
  trade-off is an O(tree) `prepare` instead of O(mutations).
- `track` takes ownership of the root without copying (like chord). Callers
  must not mutate the root after handing it over.
- `apply_immutable` deep-copies rather than sharing subtrees with the input;
  the result is fully independent of `target` and the op payloads.
