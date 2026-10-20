# 07 — Expand `replicated_state` toward chord's `state.ts`

## Objective

Close the gap between `state.cr` (simplified observable state) and chord's full
replicated-state runtime (`state.ts`, `cell.ts`, `context/`), to the extent the
Crystal port wants to adopt it.

## Current behavior

`src/llm/chord/state.cr` (243 lines) deliberately drops chord's `Context` and
async listeners (per `AGENTS.md`):

- Synchronous listener blocks (`StateListener = Proc(JSON::Any, Delivery, Nil)`).
- Hydrate-then-update delivery (`Subscriber#push`, line 40; `Publisher#publish`,
  line 94).
- Per-subscriber `Deque` backpressure, cap 100, retaining the hydration frame
  (`Subscriber#push`, line 42–47).
- Reentrancy-safe queueing (`Publisher#publish` `@delivering` guard, line 98).
- `on_error` proc.
- `MutableReplicatedState` (change/replace over a tracker) and
  `AttachedReplicatedState` (over `ReplicatedStateSource`).

chord adds: `Context` (structured provider/consumer wiring), `Cell` (derived
state), async listener delivery, and richer source/hydration semantics.

## Scope decision

The port explicitly chose synchronous, Context-free delivery as a
Crystal-idiomatic simplification. This plan is therefore **optional parity
work** and is written as phases so each can be adopted or rejected
independently.

## Phases

### Phase A — async delivery (behind opt-in)

- Add an optional `async = true` mode to `replicated_state` that delivers via
  Crystal fibers/channels (`Channel(Publication)`) instead of the synchronous
  loop.
- Keep the synchronous path as the default; preserve the hydrate-then-update and
  backpressure contract.
- Acceptance: same observable sequence as synchronous delivery, but non-blocking
  for slow listeners.

### Phase B — derived cells

- Add `Cell(JSON::Any)` — a read-only derived value recomputed from a
  `ReplicatedState` (or another cell) by a pure function, with change
  notification. This mirrors chord's `cell.ts`.
- Acceptance: a cell over `state` recomputes only when its inputs change
  (value-equality gate), and subscribers fire on change.

### Phase C — Context

- Add a lightweight `Context` that wires providers to consumers and validates
  registration, mirroring `context/` in chord without the async plumbing unless
  Phase A landed.
- Acceptance: `state = context.require(...)` style resolution; clear errors on
  missing/duplicate registration.

### Phase D — source parity

- Extend `ReplicatedStateSource`/`AttachedReplicatedState` to support the
  hydrate/update framing and cursor-gap recovery chord documents, matching
  `state.ts` source semantics.

## Affected files

- `src/llm/chord/state.cr` (or new `src/llm/chord/cell.cr`,
  `src/llm/chord/context.cr`).
- `spec/state_spec.cr` (+ new spec files per phase).

## Tests / acceptance

- Each phase ships with specs asserting the observable delivery contract and
  reentrancy/backpressure behavior.
- `crystal spec` and `ameba` remain green after each phase.

## Risks / trade-offs

- This expands scope well beyond the `delta` port and adds concurrency surface
  (fibers/channels), which carries its own correctness and deadlock risks. Adopt
  phases only when a concrete consumer needs them.
- The synchronous design is a documented intentional simplification
  (`AGENTS.md`); keep the sync path as default so existing callers are
  unaffected.
- Cells/Context add a second state concept alongside the tracker; avoid
  duplicating authority — cells must be derived (read-only), never a second
  writer.
