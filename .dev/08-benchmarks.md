# 08 — Benchmark suite parity

## Objective

Add benchmarks that exercise the delta module's hot paths, mirroring the
scenarios chord ships under `test/delta-benchmark/` and
`test/delta-traversal.bench.ts`, so performance changes to `diff.cr`/`apply.cr`/
`draft.cr` are measurable.

## Current behavior

llm-chord has specs (`spec/*_spec.cr`) and Ameba lint but **no benchmarks**.
chord ships:

- `test/delta-benchmark/benchmark.ts` + `benchmark.worker.ts`
- `test/delta-benchmark/conversation-view-benchmark.ts` + worker
- `test/delta-benchmark/memory-benchmark.ts` + worker
- `test/delta-traversal.bench.ts` (hot nested reads through the tracker)

## Target behavior

A standalone benchmark target (not run by `crystal spec`) plus a documented
command, covering the operations chord measures, adapted to the clone+diff model.

## Steps

1. Create `bench/` (or `.dev/bench/` — keep out of `spec/` so `crystal spec`
   does not run it) with a single `bench.cr` entry point using Crystal's
   `Benchmark` module.
2. Port these scenarios:
   - **Bulk unshift** — unshift N three-field objects into a change, `prepare`,
     measure (chord reports ~19 ms / ~20 MiB transient for 100k; the Crystal
     clone+diff path will differ — record, don't assert parity).
   - **Append to long array** — repeated `change.state.entries << ...` +
     `prepare` + `adopt`, measure per-iteration cost and op size.
   - **Hot nested reads** — 20k reads through `change.state` (chord measures
     proxy overhead ~9 ms vs ~0.08 ms raw; Crystal's `Draft` is a thin wrapper,
     so the comparison is informational).
   - **Structural array edit** — a splice/reorder to exercise the `p`/`m`
     emission path and, after plan 01, the anchor stages.
   - **Immutable replay** — `apply_immutable` and `apply_immutable_batches`
     over a backlog of batches (and `apply_immutable_shared`, once plan 03 lands).
   - **Memory** — a coarse resident-set measure via `/proc/self/status` or
     `GC.stats` around bulk-insert (Crystal has no worker-thread analog; keep it
     single-process).
3. Add a `README` section or a `bench/README.md` documenting
   `crystal run bench/bench.cr --release` (or `crystal build --release` then run).
4. Keep benchmarks out of `shard.yml`'s build/spec targets; do not add
   dependencies.

## Affected files

- `bench/bench.cr` (new)
- `bench/README.md` (new)
- `README.md` (one "Benchmarks" subsection with the run command)

## Tests / acceptance

- `crystal run bench/bench.cr --release` completes and prints per-scenario
  timings without error.
- `crystal spec` still runs only `spec/` (benchmarks excluded).
- No new shard dependencies.

## Risks / trade-offs

- Crystal's clone+diff `prepare` is O(tree) by design (documented in
  `AGENTS.md`), so absolute numbers will not match chord's O(mutations) overlay.
  The benchmarks are for **regression tracking**, not parity.
- `GC.stats`/`/proc` memory reads are environment-dependent; keep them advisory
  and clearly labeled.
