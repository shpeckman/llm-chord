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

### 3. Hot reload: in process, facets as values

Revised for Phase 7. Upstream's reload is in process: objects survive it with
their cells, open resources, references, leases and kept listener
subscriptions, and `reload` takes facet values (its tests use nothing else);
module paths are resolved through a pluggable `FacetLoader`. Crystal facets are
values, so upstream's reload ports one to one: a reload switches between
facets compiled into the program, and a `FacetLoader`
(`Proc(Array(String), Array(Facet))`) resolves the module names that `prepare`
frames carry, so a Crystal child takes part in a Node coordinator's reload.

- New Crystal code is a new binary: `HostManager#replace` starts it, and a
  parent reconciles a child that connects behind its code version.
- Rejected: process-level reload (one worker binary per code version, state
  migrated from the old process). A new process cannot adopt the old one's open
  resources, references or subscriptions, it would still need factories in
  recording mode against existing cells, and it would add a state-transfer
  protocol upstream does not have, with no upstream test to check it against.
- Rejected earlier, still: `dlopen`'d facet libraries (one GC and runtime per
  process, no safe unloading).

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
  `render_trace`. Since extracted into the `llm-telemetry` shard
  (`LLM::Telemetry`), which llm-chord depends on.
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

## Phase 4 — single-process runtime ✅

- Objects: the factory's `ObjectScope` (upstream's `self`: `state` with initial
  values or `init`, `get`, `resource`, `on`, `task`, `derive`, `register`,
  `expose`), activation as one transaction with unwinding, lifetimes
  (`referenced` with linger, `host`), principals and principal keys, variants,
  references with late binding, `accepts` adapters, cycle detection, forced
  disposal holders-first, `invalidate_principal` on local objects.
- `Cell` / `Derived` with hydration, write guards, dev-mode validation,
  snap/ops/reset events; the publication queue.
- Registries, `create_host` / `serve` / `install` / `load` / `ready` / `get` /
  `hold` / `root`, `define_facet` / `define_registry`.
- Acceptance: upstream's `tutorial.test.ts` sections 01–05, 07, 08, 10 and 11
  in a single process, plus the single-process cases of `state`, `state-init`,
  `host`, `readiness` and `principals`. Section 06 needs memory links and moves
  to Phase 5; section 09 needs reload and moves to Phase 7.
- Code version is a host attribute (`Host#code_version`, carried by every
  `Ctx`); it stayed 1 until reload (Phase 7).
- Deferred to the phases that need them: remote bindings, consumer-side
  linger and `GetOptions.state` (done in Phase 5); code-version retirement, gates,
  leases, staged listeners, `StateOptions` (`version`, `migrate`) and
  `Cell#reset` (done in Phase 7).

## Phase 5 — wire protocol and links ✅

- Frames and connections (`wire.cr`, `connection.cr`): protocol version 4,
  frame validation against the frame schema, hello and mismatch handling,
  holds, units and state streams with per-stream delta encoders, flow control
  (`acks`, window, `pending_cap`, unit and state slots with coalescing and
  resets), `max_calls`, ping/pong, packed (deflated) payloads above 64 KiB.
- Remote references (`remote.cr`): shared bindings per host, principal key and
  fingerprint; views by variant; `GetOptions.state` (`state: false`);
  consumer-side linger (`linger`, `linger_cap`); re-hold after reconnect.
- Links (`link.cr`, `websocket.cr`): memory, IPC (Node's channel format: one
  JSON message per line, `{"chord2": frame}`), WebSocket (`HTTP::WebSocket`,
  binary messages for packed frames) and `accept_web_sockets`.
- Relays and routes: `route` / `authorize` / `resolve`, principal stamping and
  restamping, `invalidate_principal` propagation.
- Acceptance: `tutorial.test.ts` section 06, plus the link cases of `bindings`,
  `flow`, `flow-units`, `placement`, `awaiting`, `remote` and `links-review`.
- Conformance: `conformance/` links Crystal and Node hosts (a Node server with
  a Crystal child over IPC; a Node browser on a Crystal server over a
  WebSocket). It type-checks but has not yet been run against upstream's
  sources; the Crystal side of Node IPC framing is covered by
  `spec/fixtures/node_child.mjs`.
- Deferred to Phase 7 (done there): reconciliation of children on older code
  versions and reload frames.

## Phase 6 — cluster and process management ✅

- `create_host_manager` with start/stop/replace serialized, ready timeout,
  keep-alive checks over `Liveness`, and `on_exit`.
- The fork driver on `posix_spawn`: the child leads its own process group,
  gets the IPC socket on fd 3 (`NODE_CHANNEL_FD`), and the group is killed when
  the leader exits or ignores shutdown past the grace period. It runs an
  executable with arguments, so a Node child is `node` plus its script.
- `child_control`: init, lock, ready, fatal, status reports, shutdown.
- `process_lock`: a Linux abstract-namespace Unix socket named like upstream's,
  a socket file in the temporary directory elsewhere.

## Phase 7 — reload ✅

- In-process reload from decision 3, following upstream spec §7 and
  `reload.ts`: retire, load, prepare in recording mode, gate (admission cut,
  leases, grandfathered roots, `gate_deadline`, exclusive resources), migrate
  (`StateOptions`: per-cell `version` and `migrate`), commit in one
  synchronous step, rollback, and the edge cases of the spec's "Decisions"
  (pending code version for added types, `min_code_version`, task stop
  deadline, listener events queued during the gate, removed types, lifetime
  changes, retokened host-object references).
- Code versions with the two-version rule, retirement on the last root (and
  the parent's `retire`), forced retirement after `retire_deadline`, and
  `superseded` for retired code versions; registry tables per code version.
- Cross-host reload (`cluster.ts`): `prepare`/`vote`/`commit`/`abort`/`retire`
  and `root_end` frames, `vote_deadline`, fencing and reconciliation of
  children that connect behind (also during a reload), remembered child
  modules and removal tombstones, `upgrade_required` for browsers.
- Acceptance: `tutorial.test.ts` section 09, `reload`, `host-objects-reload`,
  `cluster`, and the reload cases of `review`, `requests`, `host` and
  `variants`. Not ported: `generations.test.ts` (V8 GC) and the white-box
  "commit fails midway" case.
- Conformance: `conformance/node_parent.ts` now runs a cluster reload in which
  the Crystal child votes and commits; like the rest of the harness it has not
  yet been run against upstream's sources.

## Phase 8 — SQLite and telemetry storage

- `sqlite`: portable database interface, atomic migrations, schema-prefix
  validation, an adapter on `crystal-sqlite3` / `crystal-db` (the shard's first
  dependencies).
- `telemetry-sqlite`: buffered recording, retention, `TelemetryStore` queries.
- `sqlite/cloudflare` has no Crystal target and stays out.
