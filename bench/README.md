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

- `bulk unshift + prepare` — unshift 1k single-key objects into a change, then `prepare`. (Uses 1k, not 10k, because `Draft#unshift` is O(n) per insert under the clone+diff model.)
- `append to long array` — append 10k objects and `prepare`/`adopt`.
- `hot nested reads` — 10k reads through `change.state`.
- `immutable replay` — `apply_immutable` 10k times.
- `structural splice diff` — `diff_revisions` over a 1k-element array with a removed subsequence.

Numbers are for regression tracking, not for parity with chord: chord's overlay
is O(mutations) on `prepare`, while this port's clone+diff is O(tree) by design.
