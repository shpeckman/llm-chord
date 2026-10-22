# AGENTS.md

## Overview

`llm-chord` is a Crystal port of
[`@earendil-works/chord`](https://github.com/earendil-works/pi/tree/main/packages/chord).
It is being ported in phases tracked in `ROADMAP.md`. Phases 1–8 are done:
the delta module, replicated state, Context (values, cancellation,
telemetry), errors, output,
schemas, contracts, the single-process runtime (hosts, objects, cells,
references, roots, facets, registries), the wire protocol and links (memory,
IPC, WebSocket; relays and routes), and child host processes (host manager,
fork driver, child control, process lock), in-process reload (code
versions, gates, migration, retirement, cluster reloads and reconciliation),
and SQLite (the portable database interface, migrations, the crystal-sqlite3
adapter, and the SQLite telemetry recorder) follow upstream semantics.
Upstream's Cloudflare adapter is out of scope. Values are `JSON::Any`.

There are three dependencies:

- the `typebox` shard (`github: shpeckman/typebox`), a port of TypeBox
  1.3.27's builders and `Value` functions. Schema behavior belongs there;
  llm-chord only uses it.
- the `llm-telemetry` shard (`github: shpeckman/llm-telemetry`), the
  `@earendil-works/pi-telemetry` subset chord uses: span, metrics,
  propagation and store contracts, no-op implementations, the in-memory
  recorder, `render_trace`, clocks, and the adapter and store conformance
  suites (`require "llm-telemetry/testing"`). Telemetry behavior belongs there.
- `crystal-sqlite3` (`github: crystal-lang/crystal-sqlite3`, `~> 0.24.0`) on
  `crystal-db` 0.15, used only by `src/llm-chord/sqlite/sqlite3.cr`.

Upstream is the specification. When behavior is in doubt, read the upstream
source and tests (`packages/chord/src`, `packages/chord/test`) and match them.

## Repository layout

All code lives under `src/llm-chord/`, next to the entry point `src/llm-chord.cr`. Crystal resolves `require "llm-chord/x"` to `src/llm-chord/x.cr`, so the entry points `src/llm-chord/sqlite.cr` and `src/llm-chord/telemetry-sqlite.cr` share the folder with the implementation of `LLM::Chord`. Paths follow the shard name, not the module path.

```
src/llm-chord.cr                   Entry point: requires the tree, opens LLM::Chord
src/llm-chord/sqlite.cr            Entry point for `require "llm-chord/sqlite"` (llm-chord plus the SQLite module)
src/llm-chord/telemetry-sqlite.cr  Entry point for `require "llm-chord/telemetry-sqlite"`
src/llm-chord/json.cr              deep_copy, copy_json, identical?, equal?, to_any, js_string
src/llm-chord/errors.cr            ChordError, ErrorCode, AggregateError, helpers
src/llm-chord/context.cr           Context, ContextKey(T), AbortSignal/AbortController, await, telemetry
src/llm-chord/output.cr            bound, sanitize, Buffer (streaming UTF-8 decoder), Progress, clocks
src/llm-chord/delta/types.cr       Seg/Path/WireOp, Op hierarchy, from_tuple/to_tuple, validation, errors
src/llm-chord/delta/utf16.cr       UTF-16 code-unit counting and slicing
src/llm-chord/delta/overlap.cr     String suffix/prefix overlap helper
src/llm-chord/delta/diff.cr        diff_revisions (identity-anchored structural diff)
src/llm-chord/delta/apply.cr       apply, apply_immutable, apply_immutable_batches (copy-on-write)
src/llm-chord/delta/codec.cr       Encoder/Decoder (path interning + arity omission)
src/llm-chord/delta/draft.cr       Draft: revocable copy-on-write handles
src/llm-chord/delta/tracker.cr     Overlay, Change, Prepared, Tracker, track
src/llm-chord/state.cr             replicated_state: publisher, subscribers, mutable and attached state
src/llm-chord/schema.cr            canonical_json, hash64, normalize, canonical_identity, assert_valid, fits?
src/llm-chord/contract.cr          method/opaque, placement, remote/local, Description, coverage, bind
src/llm-chord/future.cr            Future(T) (promise analogue on fibers), race, await_all
src/llm-chord/publish.cr           Publish: the one FIFO queue for every observer notification
src/llm-chord/readable.cr          RefStatus, Shape, StateEvent, Subscribable, Readable, Listeners(T), json_value
src/llm-chord/cell.cr              Fanout, Source, Cell (boxed tracker), Derived, compute_dependents
src/llm-chord/registry.cr          Registry(V), RegistryValue(V), RegistryView(V), define_registry
src/llm-chord/resource.cr          AnyResource, Resource(T), Exposed
src/llm-chord/implementation.cr    Implementation builder, MethodFn, OpaqueBox(T)
src/llm-chord/ctx.cr               Ctx (call context), linked_signal, await_ready
src/llm-chord/ref.cr               Ref (shared reference API), LocalRef, MemberReadable
src/llm-chord/remote.cr            RemoteBinding (shared hold), ViewReadable, RemoteRef
src/llm-chord/object.cr            Service, Decls, Run, Installed, Gate, StagedListeners, ObjectImpl (activation, calls, leases, disposal)
src/llm-chord/scope.cr             ObjectScope: what a factory declares (upstream's `self`)
src/llm-chord/facet.cr             Facet, define_facet, FacetApi, FacetLoader
src/llm-chord/host.cr              CodeVersion; Host: services, addresses, roots, retirement, registries, principals, links, routes, close
src/llm-chord/reload.cr            ReloadOptions, ReloadReport, Candidate, Reload (prepare, gate, migrate, commit, rollback)
src/llm-chord/cluster.cr           Cluster (coordinated reload, reconciliation), ChildReloads (prepare/vote/commit on a child)
src/llm-chord/wire.cr              PROTOCOL_VERSION, Frame, Packed, Wire (schema, errors, encodings)
src/llm-chord/link.cr              Link, BaseLink, MemoryLink, IpcChannel, IpcLink
src/llm-chord/connection.cr        LinkOptions, Connection: hello, holds, units, flow control, calls, relays
src/llm-chord/websocket.cr         WebSocketLink, accept_web_sockets
src/llm-chord/manager.cr           Fork driver (posix_spawn), HostManager, ChildControl, process_lock
src/llm-chord/sqlite/database.cr   Value, Row, Error, Executor, Database (upstream sqlite/database.ts)
src/llm-chord/sqlite/schema.cr     validate_schema_prefix (sqlite/schema.ts)
src/llm-chord/sqlite/migrations.cr Migration, apply_migrations (sqlite/migrations.ts)
src/llm-chord/sqlite/sqlite3.cr    SerialQueue, Sqlite3Database, Sqlite3Transaction, open_database (sqlite/node.ts)
src/llm-chord/telemetry_sqlite/recorder.cr  SqliteTelemetry: recording, buffering, flush/close, create_sqlite_telemetry (telemetry-sqlite/index.ts)
src/llm-chord/telemetry_sqlite/store.cr     SqliteTelemetry.get_trace/find_traces/find_metrics (telemetry-sqlite/store.ts)
spec/                              Crystal specs, largely translated from upstream tests
spec/fixtures/                     Child processes for the manager specs (Crystal worker, Node child)
spec/support/                      Shared spec code: the SQLite telemetry fixtures and spy database
conformance/                       Crystal ↔ Node link conformance harness (run.sh, needs CHORD_SRC)
bench/                             Release-mode micro-benchmarks
ROADMAP.md                         Porting phases and settled design decisions
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
The specs never hit the network; the WebSocket specs listen on 127.0.0.1 and
`spec/manager_spec.cr` builds `spec/fixtures/worker.cr` into the temporary
directory. The Node child spec is pending when `node` is missing. The SQLite
specs need libsqlite3 (3.37+) and use in-memory databases.
`conformance/run.sh` needs upstream chord's sources in `CHORD_SRC`.

## Code standards

- Every Crystal file opens with a single comment naming its path, e.g.
  `# src/llm-chord/delta/diff.cr`. No other comments in code.
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
- Telemetry lives in the `llm-telemetry` shard as `LLM::Telemetry`; chord only
  uses it (`Context#telemetry`, `#with_telemetry`, `#trace_in`). Inside
  `LLM::Chord` and in specs (which `include LLM::Chord`), write the full
  `LLM::Telemetry::` path. Changes to spans, metrics, propagation, the
  in-memory recorder or `render_trace` belong in that shard.
- Upstream promises map to blocking calls on fibers. Work that upstream starts
  without awaiting (an async listener, a progress `write`, `awaitWithContext`)
  is spawned; results come back through channels.
- Compiler quirk: a method that captures a block (`&block : ...`) and also
  contains a proc literal (`-> { }`) can fail with "read before assignment" for
  the block variable. Keep the proc literal in a separate private method, as
  `AbortSignal#remover` and `SystemClock#disarmer` do.
- `Output` counts bytes on UTF-8 strings; its byte decoder follows the WHATWG
  UTF-8 decoder exactly, including how many U+FFFD an invalid sequence yields.
- The differential harness used during Phase 1 generated cases with upstream's
  `diffRevisions` and `track` under Node and compared op batches and values;
  re-run something similar when changing `diff.cr` or the tracker. Phase 2 did
  the same for `Output.bound`, `sanitize`, and `Buffer` snapshots, including
  byte chunks with invalid UTF-8, BOMs, and skips.
- Phase 3 ran upstream's `src/contract.ts` and `src/schema.ts` directly under
  `node --experimental-strip-types` (with `typebox` linked into the package's
  `node_modules`) on generated contracts, and compared descriptions,
  fingerprints, `hash64`, normalized inputs and identities, `coverage`, and
  `fits`. Re-run it when changing `schema.cr`, `contract.cr`, or the typebox
  shard.
- Contracts keep descriptions as raw JSON (`Description#json`) so a received
  token fingerprints exactly as sent; typed accessors read from it. Build
  descriptions only in `remote` / `local`, in upstream's key order.
- `bind` is generic over the adapter type (`Hash(Int32, A)`); the runtime's
  adapter is `Proc(Implementation, Implementation)`. `Description#variants` is
  memoized: the runtime reads it on every call.
- Runtime internals are `protected`: Crystal lets types in the same namespace
  (`LLM::Chord`) call them, while user code cannot. Keep new internals
  `protected` or `private` rather than public.
- The runtime is single-threaded like upstream's event loop: `Publish` and the
  host's counters are unsynchronized. Upstream's synchronous prefix of an async
  function (an activation's factory, a disposal's status change, an
  invocation's registration) runs in the caller; the rest is spawned. Track a
  spawned invocation before spawning (`ObjectImpl#track`) so disposal waits
  for it.
- `Future(T)` stands in for promises. Its `on_settle` callbacks run
  synchronously at settlement, in registration order (activation success
  makes references live before `ready` resolves, as upstream's `then` chain
  does). `wait(signals, timeout)` returns an `Outcome` instead of raising, so
  callers build upstream's exact errors.
- Cells track `{"v" => value}` because the tracker needs container roots;
  `Cell.unbox` strips the box from published ops (an op on the value itself
  becomes `r`). Derived values start as `nil` (upstream's `undefined`), so their
  first install publishes `r`.
- `Listeners(T)` keeps listeners by integer id: callers snapshot before
  delivering and skip ids removed meanwhile, as upstream does with `Set`
  membership.
- Reload is in process (ROADMAP decision 3): facets are values, and a
  `FacetLoader` maps the module names of `prepare` frames to compiled-in
  facets. A host keeps `CodeVersion`s (`current`, `previous`, and a running
  reload's `pending`), each with its services, registry tables, running roots
  and an abort controller (forced retirement). An object installs an
  implementation per retained code version whose service it was built from.
- `Reload` follows upstream's `reload.ts` step by step: `prepare` (retire the
  previous code version, load, check providers, prepare objects to a fixpoint,
  gate, stage listeners) then `commit` (one `Publish.hold` step; work that may
  start new-code roots is queued in `@starts` and runs after the coordinator's
  `before_start` sent its commit frames). Everything fallible runs in prepare;
  a commit that still raises fails the host (`unavailable/host_failed`).
- A factory rerun gets the previous `Decls`: `ObjectScope` returns the kept
  cell, reference and resource by name or address. Kept resources record an
  adopter proc in `Decls#adopted`, run at commit. Listener subscriptions are
  kept when origin and selector pointer match (`Subscription#same_source?`).
- Leases: `ObjectImpl#call` and listener roots `lease` the object; the host's
  `touch` table ends them in `end_root` (also for foreign roots, on `root_end`).
  A gate grandfathers the leases present at its cut.
- Cluster frames: the coordinator's `Cluster.reload` sends `prepare`, collects
  `vote`s from `Connection#votes`, then `commit` or `abort`; `ChildReloads`
  runs the child side. `Connection#admit_root` admits roots of fenced code
  versions in the parent's current one.
- The acceptance spec is `spec/tutorial_spec.cr`: upstream's
  `tutorial.test.ts` sections 01–11. `spec/cell_spec.cr`, `state_init_spec.cr`,
  `host_spec.cr` and `readiness_spec.cr` translate the single-process cases of
  the matching upstream tests; `reload_spec.cr`, `host_objects_reload_spec.cr`
  and `cluster_spec.cr` translate `reload`, `host-objects-reload`, `cluster`
  and the reload cases of `review`, `requests`, `host` and `variants`. Specs
  that inspect state another fiber delivers (a commit frame over a memory link)
  wait with `eventually`, where upstream relies on microtask order.
  `generations.test.ts` (V8 `FinalizationRegistry`) and the white-box
  "commit fails midway" case are not translatable.
- `Link` collides with Crystal's top-level `@[Link]` annotation: specs and
  any code including `LLM::Chord` write `LLM::Chord::Link`.
- Frames are `Frame` objects (fields plus an optional `Packed` payload), built
  through `Wire`/`Frame` helpers, never raw hashes; `Frame.state` exists
  because `as` cannot be a named argument. Size accounting is UTF-8 bytes.
- Connection bookkeeping lives in `Connection`; the host owns bindings, routes,
  linger and invalidation. A new frame type touches `Wire::FRAME_SCHEMA` and
  `Connection#dispatch`.
- `create_host` is a macro and `LinkOptions` takes any `Int`, because symbol
  and number autocasts are lost through `**options` forwarding.
- The fork driver binds `posix_spawn` in `LibChordSpawn`; the child is awaited
  through `Process.new(Crystal::System::Process.new(pid))`. IPC is Node's
  `json` serialization over fd 3, so Crystal and Node children are
  interchangeable.
- SQLite follows upstream's `sqlite/` and `telemetry-sqlite/` file by file.
  Upstream promises map to blocking calls: `Sqlite3Database` runs every
  operation through a `SerialQueue`, a FIFO handoff queue (one channel per
  waiter, release hands the turn to the next waiter), because a `Mutex` lets
  a releasing fiber barge ahead of waiters and upstream guarantees call order.
  A transaction holds the queue for its whole block.
- crystal-sqlite3 prepares statements with `sqlite3_prepare_v2` and ignores
  the SQL after the first statement, and its own transactions use plain
  `BEGIN`. So `exec` calls `LibSQLite3.exec` on `Connection#to_unsafe`, and
  transactions run `BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK` through it. The
  connection is built directly (`SQLite3::Connection.new`), not through
  `DB.open`'s pool, so `:memory:` is one database and paths need no URI
  encoding.
- `Executor`'s abstract methods take `Array(Value)` (`run_values`,
  `get_values`, `all_values`); `run`/`get`/`all` are splat conveniences
  defined once in the base class. A wrapper database (as in
  `spec/support/telemetry_sqlite.cr`) must hold a concrete database type:
  yielding through an abstract `Database` that includes the wrapper itself is
  a recursive block expansion.
- SQLite telemetry writes JSON with `Schema.stringify` (insertion order) and
  series attributes with `Schema.canonical_json` (sorted keys), both exactly as
  `JSON.stringify` writes them, so the database file is shared with Node
  recorders (ROADMAP Phase 8 decision). Never use `to_json` for stored JSON.
- `SqliteTelemetry` recognizes spans by type (`identity_of` over `LiveSpan`
  and `ExtractedParent`), the equivalent of upstream's module-wide `WeakMap`.
  Time, durations and the flush timer come from its `LLM::Telemetry::Clock`;
  specs pass a `ManualClock` where upstream mocks `Date.now` or uses fake
  timers. Specs replace `vi.spyOn(db, "transaction")` with `SpyDatabase`
  (`before_transaction`, `failure`, counters), which resets its transaction
  count after `create_sqlite_telemetry` because the migration runs one.
- `spec/telemetry_sqlite_spec.cr` and `spec/telemetry_sqlite_store_spec.cr`
  translate `telemetry-sqlite.test.ts` and `telemetry-sqlite-store.test.ts`
  and run llm-telemetry's adapter (without the `metrics` group, as upstream)
  and store conformance suites; `spec/sqlite_*_spec.cr` translate
  `sqlite/migrations.test.ts` and `sqlite/node.test.ts`. The Durable Object
  variants are not ported.
