# Benchmarks

Delta-module micro-benchmarks, ported from the scenarios chord ships under
`test/delta-benchmark/` and `test/delta-traversal.bench.ts`.

Run them in release mode (not part of `crystal spec`):

```console
crystal run bench/bench.cr --release
```

or build once and run:

```console
crystal build bench/bench.cr --release -o /tmp/llm-chord-bench
/tmp/llm-chord-bench
```

## Scenarios

- `bulk unshift + prepare` — unshift 10k single-key objects into one change, then `prepare`.
- `append to long array` — append 10k objects and `prepare`/`adopt`.
- `hot nested reads` — 10k reads through `change.state`.
- `small edit in a large revision` — 100 consecutive one-field changes on a 10k-row revision.
- `immutable replay` — `apply_immutable` 10k times.
- `structural splice diff` — `diff_revisions` over a 1k-element array with a removed subsequence.

Numbers are for regression tracking. The tracker is copy-on-write: a change
copies only the containers on the paths it writes, and `prepare` diffs the base
against the draft with identity short-circuits, so untouched subtrees cost
nothing. A change inside a large flat array still copies that array's slots,
as in chord.
