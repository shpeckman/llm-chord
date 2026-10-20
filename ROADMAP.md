# Roadmap

The goal is a faithful Crystal port of
[`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord)
(v1.3.0 at the time of writing). Upstream source and tests are the
specification; each phase translates the matching upstream tests into specs.

## Open decisions

These shape everything from Phase 3 on and should be settled before it starts.

1. **Wire interop with TypeScript hosts.** If Crystal hosts must link to Node
   hosts or browsers, protocol v4 frames, contract fingerprints (canonical
   schema JSON, 64-bit hash), and the delta wire format must match upstream
   byte for byte.
2. **Hot reload.** Crystal cannot load new code into a running process.
   Options: process-level reload (each code version is a worker binary;
   prepare/vote/commit across processes), `dlopen`'d facet libraries (fragile),
   or leaving reload out and documenting it.
3. **Schemas.** Upstream uses TypeBox. Options: a data-driven schema DSL that
   validates `JSON::Any` and emits canonical JSON Schema, or an existing JSON
   Schema shard that can produce TypeBox-identical canonical output.

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

## Phase 2 — standalone modules

- **Context, complete:** cancellation (`with_cancel`, `with_abort_signal`,
  `without_abort_signal`, `await_with_context`) built on fibers and channels;
  telemetry spans (`with_telemetry`, `trace_in`), which needs a minimal port of
  `@earendil-works/pi-telemetry`'s span interface and no-op span.
- **Errors:** `ChordError` with upstream's codes and reasons.
- **Output:** `OutputBuffer`, `bound_output`, `sanitize_output`,
  `utf8_byte_length`, `Progress`.
- **JSON:** `JsonRevisionValidator` (incremental validation that skips
  containers already validated).

## Phase 3 — schemas and contracts

- The schema layer chosen above.
- `local`, `remote`, `method`, `opaque`, `bind`, `coverage`; `host_named` /
  `host_family` placement; variants, versions, the compatibility rule;
  canonical input identity; fingerprints.

## Phase 4 — single-process runtime

- Objects: factory `self` (`state`, `derive`, `resource`, `on`, `task`),
  lifetimes and linger, principals and variants, references.
- `Cell` / `Derived` with hydration, write guards, snap/ops/reset events; the
  publication queue.
- Registries, `create_host` / `serve` / `root`, `define_facet` /
  `define_registry`.
- Acceptance: upstream's `tutorial.test.ts` over memory links.

## Phase 5 — wire protocol and links

- Frames and connections: validation, holds, units and state streams,
  per-stream delta encoders, flow control (`acks`, window, `pendingCap`, slot
  coalescing), `max_calls`, ping/pong.
- Links: memory, IPC (Unix socketpair or pipes, line-delimited JSON),
  WebSocket (`HTTP::WebSocket`, plus an `accept_web_sockets` equivalent).
- Relays and routes: `route` / `authorize` / `resolve`, principal stamping.

## Phase 6 — cluster and process management

- `create_host_manager`, fork driver on `Process.new`, child control channel,
  liveness reports, process-group kill.
- `process_lock` (Linux abstract-namespace Unix socket).

## Phase 7 — reload

- The approach chosen above, following upstream spec §7: load, prepare/vote,
  gate, migrate, commit, retire; the edge cases in the spec's "Decisions".

## Phase 8 — SQLite and telemetry storage

- `sqlite`: portable database interface, atomic migrations, schema-prefix
  validation, an adapter on `crystal-sqlite3` / `crystal-db` (the shard's first
  dependencies).
- `telemetry-sqlite`: buffered recording, retention, `TelemetryStore` queries.
- `sqlite/cloudflare` has no Crystal target and stays out.
