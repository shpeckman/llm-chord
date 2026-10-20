# 01 — Richer array matching in `diff.cr`

## Objective

Make `diff_revisions` emit smaller (more granular) operation batches for arrays,
matching the spirit of chord's multi-stage array matcher. Today `diff.cr`
produces larger whole-region `p` splices on large or repetitive arrays.

## Current behavior

`src/llm/chord/delta/diff.cr` has one matching stage beyond prefix/suffix trim:

- `diff_array_region` (line 108): trims equal prefix/suffix, then a positional
  `==` scan (`process_array_matches`, line 155), then a single deep-equality LCS
  (`lcs_matches`, line 175) with a hard cell budget `MAX_LCS_CELLS = 65_536`
  (line 10). When the budget is exceeded it returns `nil` and the region is
  emitted as one `Op::Splice`.
- No identity subsequence, no identity anchors, no greedy fallback, no semantic
  alignment.

Reference: `packages/chord/src/delta/diff.ts` stages, in order:

1. `identitySubsequence` (line 151) — cheap linear scan when one side is a strict subsequence.
2. `identityAnchors` (line 203) — LIS over position lists, with `greedyIdentityAnchors` (line 183) as a fallback past `MAX_IDENTITY_CANDIDATES = 200_000` (line 86).
3. `lcsMatches` with `semanticallyAligned` (line 124), `MAX_SEMANTIC_CELLS = 65_536` (line 87).

## Key constraint: no object identity in Crystal

chord's stages 1–3 are keyed by **object identity** (`Map<JsonValue, number[]>`
uses SameValueZero; `sameValue` is `left === right || equalJson`; the semantic
"shares a child container" test is identity too). `JSON::Any` is a **value
struct** and `begin_change` (`tracker.cr:28`) deep-copies the base, so identity
is never a reliable signal in llm-chord. The plan must therefore substitute
**deep equality** for identity everywhere, and drop the identity-only semantic
test.

## Target behavior

After the change, `diff_array_region` runs these stages in order, all using
`==` (deep equality) as the element-equality predicate:

1. Prefix/suffix trim (unchanged).
2. Positional `==` scan (unchanged).
3. **Value subsequence** — port of `identitySubsequence`: if one side's values
   are a strict subsequence of the other, emit granular matches via a linear
   scan. O(n+m).
4. **Value anchors with greedy fallback** — port of `identityAnchors`, keyed by
   `JSON::Any` equality (a `Hash(JSON::Any, Array(Int32))` of positions, built
   with `==`/`hash`). Use an LIS over `(before_index, after_index)` candidates;
   if the candidate count exceeds a `MAX_IDENTITY_CANDIDATES = 200_000`
   constant, fall back to a greedy forward scan (port of
   `greedyIdentityAnchors`).
5. **LCS** — keep `lcs_matches` as the last resort, but only run it within the
   existing `MAX_LCS_CELLS` budget, exactly as today.
6. `permutation` fast path and the `before_count == 1 && after_count == 1`
   recurse (lines 148–150) stay unchanged.

Semantic LCS (`semanticallyAligned`) is **not** ported: its "shared container
child" predicate has no value-semantics equivalent that differs from deep
equality, so it adds no signal. Document this omission in the plan's notes.

## Steps

1. Add constants to `diff.cr`:
   `MAX_IDENTITY_CANDIDATES = 200_000` (and keep `MAX_LCS_CELLS`).
2. Extract the element-equality predicate used today (bare `==`) into a private
   `same_value(a, b) : Bool` returning `a == b`, so the stages share one
   definition.
3. Port `identitySubsequence` → `private def subsequence_matches(before, after, b0, b1, a0, a1) : Array({Int32, Int32})?`.
   Keep chord's three cases: `after_count < before_count`, `before_count < after_count`,
   and equal counts returning `nil`.
4. Port `greedyIdentityAnchors` → `private def greedy_anchors(positions, after, a0, a1) : Array({Int32, Int32})`.
   Use `lower_bound` binary search over the sorted position array (port of `lowerBound`, diff.ts:140).
5. Port `identityAnchors` → `private def identity_anchors(before, after, b0, b1, a0, a1) : Array({Int32, Int32})`.
   Build `positions : Hash(JSON::Any, Array(Int32))` with `==`/`hash`; count candidates;
   if `> MAX_IDENTITY_CANDIDATES` return `greedy_anchors(...)`; else run the LIS
   over candidates (port of diff.ts:227–250).
6. Wire the stages into `diff_array_region` between the positional scan and the
   LCS call, in the order above; skip a stage only when it returns `nil` or an
   empty array.
7. Reuse `process_array_matches` unchanged for every stage's match list.

## Affected files

- `src/llm/chord/delta/diff.cr` (only).

## Tests / acceptance

- Extend `spec/diff_spec.cr`:
  - Large array with a strictly-ordered subsequence ⇒ granular `s`/`d`/`p`, not one region splice.
  - Repetitive array past the candidate budget ⇒ greedy path runs and the batch is ≤ the old splice size.
  - Array of structurally-equal-but-distinct objects still converges (apply(ops) == after).
  - Round-trip property: for random small arrays, `apply_immutable(before, diff_revisions(before, after)) == after`.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- Batches remain "exact but not canonical": different, still-correct op shapes
  are acceptable; the goal is ≤ old size, not identity with chord's exact output.
- `Hash(JSON::Any, ...)` keyed by deep equality collapses equal values — the
  anchors are value-based, so they can match equal-but-unrelated elements. This
  is already true of the existing LCS; it cannot corrupt the result, only the
  batch shape.
- The LIS stage is O(n log n) after the O(n+m) position build; keep the
  candidate budget so worst-case stays bounded.
