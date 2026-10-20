# Roadmap

The goal is a faithful Crystal port of
[`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord)
(v1.3.0 at the time of writing). Upstream source and tests are the
specification; each phase translates the matching upstream tests into specs.

## Decisions

Settled before Phase 3; they shape everything from there on.

### 1. Wire-compatible with TypeScript hosts

Crystal hosts speak chord's protocol v4 exactly as chord 1.3.0 does: frames,
contract fingerprints, and the delta wire format match upstream byte for byte.
The pinned upstream version moves only when both sides move together.

- Chord's model includes browser clients, which run TypeScript, so a Crystal
  server is useful only if it speaks upstream's protocol.
- Mixed links make upstream the conformance oracle for the whole protocol:
  Node hosts linked to Crystal hosts, exercised end to end.
- The delta wire format already matches; the only other byte-exact
  requirement is fingerprints, which decision 2 covers.

### 2. Schemas: a data-driven DSL that emits TypeBox's JSON Schema

Upstream fingerprints a contract as `hash64(canonicalJson(description))`
(`schema.ts`): sorted-key JSON of the description, which embeds TypeBox
schemas, and TypeBox schemas are plain JSON Schema objects. Matching
fingerprints therefore needs the same JSON Schema data, not TypeBox itself.

- A schema builder mirroring the TypeBox constructors chord contracts use
  (object, string, number, integer, boolean, literal, array, union, optional,
  nullable, record, defaults), stored as JSON so canonical output and
  fingerprints fall out directly. `canonical_json` and `hash64` (two FNV-1a
  lanes over UTF-16 code units) are ported verbatim.
- Implemented as the separate `typebox` shard (a port of TypeBox 1.3.27's
  builders and `Value` functions), which llm-chord depends on.
- The runtime operations chord uses, for the subset the builder emits:
  validation with error paths (`Value.Check` / `Value.Errors`), defaults
  (`Value.Default`), and stripping unknown fields (`Value.Clean`).
- Verified against TypeBox under Node on generated schemas and values: schema
  JSON, fingerprints, validation outcomes, defaulted and cleaned values.
- No third-party JSON Schema shard: none produces TypeBox-identical output, and
  validators do not provide default and clean semantics.
- A macro deriving schemas from Crystal structs may come later, emitting the
  same JSON.

### 3. Hot reload: process-level, one worker binary per code version

Crystal cannot load new code into a running process, so a code version is a
worker binary. A reload starts the new binary, runs prepare there (factories
in recording mode), migrates state from the old process (already JSON), votes,
and commits by switching routing; the old process keeps serving in-flight roots
on the previous version until it retires. This reuses upstream's code versions,
the two-version rule, cross-host prepare/vote/commit, child reconciliation, and
the host manager.

- Costs: reload granularity is a whole worker, not a single plugin; a reload
  takes a process start plus a handshake; while both versions are live, calls
  between them cross IPC.
- Rejected: `dlopen`'d facet libraries (one GC and runtime per process, no
  safe unloading); leaving reload out (acceptable only as a stopgap).
- Constraint on earlier phases: Phases 4–6 treat the code version as an
  attribute of a host that can be pinned to a process, never assuming the
  current and previous versions share memory.

## Phase 1 — delta, Context values, replicated state ✅

- Typed ops with validating constructors, `Op.from_tuple`/`to_tuple`,
  `assert_valid_wire_op`, `base?`/`replace?`.
- Identity-anchored `diff_revisions` matching upstream (verified against
  upstream on generated cases, including shared subtrees).
- Copy-on-write `apply_immutable` and `apply_immutable_batches`; `apply`
  adopts payloads; JavaScript splice clamping.
- Copy-on-write tracker with structural sharing, revocable `Draft` handles,
  and the full open/prepared/consumed/aborted/stale lifecycle;
  `prepare_replace` emits `r`.
- `Draft` mutators: `fill`, `copy_within`, `size=`, JavaScript default sort,
  handles that follow reindexing.
- `Context` with typed keys; replicated state with contexts, isolated error
  reporting, newest-wins overflow, async subscriptions, attached sources with
  cursor validation and aggregate disposal errors.

## Phase 2 — standalone modules ✅

- **Context, complete:** `AbortSignal` / `AbortController`, `with_abort_signal`,
  `without_abort_signal`, `with_cancel`, `await` (channel or block), telemetry
  (`telemetry`, `with_telemetry`, `trace_in`).
- **Telemetry:** the pi-telemetry subset chord uses — span, context, metrics,
  propagation, and store contracts; the no-op context; the
  `InMemoryTelemetryContext` reference recorder with `TelemetryStore` queries;
  `render_trace`.
- **Errors:** `ChordError` with upstream's codes and reasons, `chord_error?`,
  `forbidden`, `invalid`, `as_chord_error`, `run_all`.
- **Output:** `bound`, `sanitize`, `Buffer` with a WHATWG UTF-8 stream decoder
  and skips, `Progress` with an injectable clock. Verified against upstream on
  generated cases.
- Not ported, on purpose: chord's `JsonRevisionValidator` (neither exported
  nor used upstream) and pi-telemetry's typed schema helpers (TypeScript
  type-level only). pi-telemetry's adapter conformance suite can come with
  Phase 8, where the SQLite recorder needs it.

## Phase 3 — schemas and contracts ✅

- The schema DSL from decision 2 as the `typebox` shard: builders, `Check`,
  `Errors` (with en_US messages), `Default`, `Clean`, `Clone`, verified against
  TypeBox 1.3.27 on generated schemas and values.
- `LLM::Chord::Schema`: `canonical_json`, `hash64`, `deep_equal?`,
  `assert_valid`, `normalize`, `canonical_identity`, `fits?`.
- `local`, `remote`, `method`, `opaque`, `bind`, `coverage`; `host_named` /
  `host_family` placement with `resolve_host` / `placed_on?`; variants,
  versions, the compatibility rule; canonical input identity; fingerprints;
  `contract_from_description` and `DESCRIPTION_SCHEMA` for tokens.
- Verified against upstream chord under Node on generated contracts:
  descriptions, fingerprints, `hash64`, normalization and identities,
  `coverage` (every outcome), and `fits` in both directions.

## Phase 4 — single-process runtime

- Objects: factory `self` (`state`, `derive`, `resource`, `on`, `task`),
  lifetimes and linger, principals and variants, references.
- `Cell` / `Derived` with hydration, write guards, snap/ops/reset events; the
  publication queue.
- Registries, `create_host` / `serve` / `root`, `define_facet` /
  `define_registry`.
- Acceptance: upstream's `tutorial.test.ts` over memory links.
- Code version is a host attribute pinnable to a process (decision 3).

## Phase 5 — wire protocol and links

- Frames and connections: validation, holds, units and state streams,
  per-stream delta encoders, flow control (`acks`, window, `pendingCap`, slot
  coalescing), `max_calls`, ping/pong.
- Links: memory, IPC (Unix socketpair or pipes, line-delimited JSON),
  WebSocket (`HTTP::WebSocket`, plus an `accept_web_sockets` equivalent).
- Relays and routes: `route` / `authorize` / `resolve`, principal stamping.
- Conformance: Crystal and Node hosts linked to each other over IPC and
  WebSocket links, per decision 1.

## Phase 6 — cluster and process management

- `create_host_manager`, fork driver on `Process.new`, child control channel,
  liveness reports, process-group kill.
- `process_lock` (Linux abstract-namespace Unix socket).

## Phase 7 — reload

- Process-level reload from decision 3, following upstream spec §7: load (start
  the new worker binary), prepare/vote, gate, migrate, commit, retire; the edge
  cases in the spec's "Decisions".

## Phase 8 — SQLite and telemetry storage

- `sqlite`: portable database interface, atomic migrations, schema-prefix
  validation, an adapter on `crystal-sqlite3` / `crystal-db` (the shard's first
  dependencies).
- `telemetry-sqlite`: buffered recording, retention, `TelemetryStore` queries.
- `sqlite/cloudflare` has no Crystal target and stays out.
