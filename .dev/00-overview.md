# Gap plans — index

Implementation plans for the gaps between `llm-chord` and `@earendil-works/chord`
(its `delta` module). Each file below is a self-contained plan. Reference
sources: `packages/chord/src/delta/*` (TypeScript) and `src/llm/chord/**`
(Crystal).

| # | File | Gap | Priority | Depends on |
|---|------|-----|----------|------------|
| 01 | `01-diff-identity-anchors.md` | Richer array matching in `diff.cr` (batch compactness) | High | — |
| 02 | `02-draft-array-mutators.md` | Array/object mutation surface on `Draft` | High | — |
| 03 | `03-apply-copy-on-write.md` | Copy-on-write / structural-sharing applier (perf) | Medium (optional) | — |
| 04 | `04-validation-and-codec.md` | Strict-JSON validator + op/wire-op shape validation | Medium | — |
| 05 | `05-string-unit-semantics.md` | UTF-16 code-unit semantics for `t`/`a`/`overlap` | High (interop correctness) | — |
| 06 | `06-type-safety.md` | Generic typed access over `JSON::Any` | Low (large redesign) | — |
| 07 | `07-replicated-state-parity.md` | Expand `state.cr` toward chord's `state.ts` | Low (large, optional) | — |
| 08 | `08-benchmarks.md` | Benchmark suite parity | Low | 01, 03 |

## Recommended order

1. `05-string-unit-semantics` — smallest, fixes a real replica-divergence bug.
2. `02-draft-array-mutators` — highest everyday ergonomics value, local to one file.
3. `01-diff-identity-anchors` — batch-size win, local to `diff.cr`.
4. `04-validation-and-codec` — hardening, spreads across `codec.cr`/`apply.cr`/`json.cr`.
5. `03-apply-copy-on-write` — only if profiling shows `apply` cost matters.
6. `08-benchmarks` — after 01/03 so it measures the new paths.
7. `06-type-safety`, `07-replicated-state-parity` — large, design-shaping; treat as separate efforts.

## Conventions used across these plans

- Values are `JSON::Any`; paths are `Seg = String | Int32`, `Path = Array(Seg)`.
- Array indices are `Int32`; JSON integers are `Int64` (converted at the codec
  boundary).
- The op vocabulary is `r`/`s`/`d`/`a`/`t`/`p`/`m` (`Op::Replace` … `Op::Move`).
- The wire codec is the only place that knows the JSON tuple form.
- Every plan keeps the observable contract (value, op vocabulary,
  no-op/stale/adopt semantics) intact; plans never change `shard.yml`.
