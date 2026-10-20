# 06 — Generic typed access over `JSON::Any`

## Objective

Recover part of chord's static type safety. chord is fully generic
(`track<T extends object>`, `Draft<T>`, `Prepared<T>`, `Tracker<T>`,
`JsonRepresentation<T>`); llm-chord uses untyped `JSON::Any` with runtime
`.as_*` casts.

## Current behavior

- `track(initial : JSON::Any)`, `Tracker#value : JSON::Any`,
  `Change#state : Draft`, `Prepared#base/value : JSON::Any` — all untyped.
- `Draft` exposes `as_s/as_i/as_f/as_bool/as_a/as_h` and `null?`
  (`draft.cr:46–72`), but there is no compile-time type tracking.

## Scope decision

A full `Track(T)` generic that preserves application types through the draft is
a major redesign and conflicts with the port's "values are `JSON::Any`"
foundation (see `AGENTS.md` conventions). This plan therefore targets the
**achievable, high-value subset** and leaves full generics as a separate,
explicitly-scoped effort.

## Approach (recommended)

Typed view wrappers + `JSON::Serializable` interop, layered without changing the
core `JSON::Any` model:

### Phase A — typed accessors on `Draft`

Add typed getters/setters that cast at the boundary and fail fast:

- `Draft#as(T : Class)` / generated accessors, e.g. `string?(key) : String?`,
  `int(key) : Int64`, `array(key) : Array(JSON::Any)`, `object(key) : Hash(...)`
  returning typed values instead of requiring manual `.as_*` at call sites.
- Keep the existing untyped methods; the typed ones are conveniences.

### Phase B — `JSON::Serializable` bridge

Add helpers to materialize a `JSON::Any` subtree into a `JSON::Serializable`
struct and to convert a serializable struct back into `JSON::Any` (via
`to_json`/`from_json`):

- `Json.to_struct(T, value : JSON::Any) : T` — `T.from_json(value.to_json)`.
- `Json.from_struct(value : T) : JSON::Any` — `JSON.parse(value.to_json)`.

This gives end-to-end typed reads/writes for callers who have struct types,
matching `Json.to_any`'s round-trip idiom (`json.cr:26`).

### Phase C — a typed tracker wrapper (optional, separate)

A thin generic `TypedTracker(T)` that wraps a `Tracker` and returns
`T` materialized via `Json.to_struct`, and feeds mutations back through
`from_struct`. Mark this as a follow-up; it is not required for the first two
phases and needs its own design review for mutation ergonomics.

## Steps

1. Phase A: add the typed accessors to `Draft`; implement in terms of the
   existing raw access, adding one clear raise on type mismatch.
2. Phase B: add `Json.to_struct`/`Json.from_struct` to `json.cr`.
3. Document both in `README.md` API list and a short typed-access example.
4. Phase C: only after A/B land and only if a consumer needs it — write a
   separate plan.

## Affected files

- `src/llm/chord/delta/draft.cr` (Phase A)
- `src/llm/chord/json.cr` (Phase B)
- `README.md`
- `spec/draft_spec.cr`, `spec/json_spec.cr`

## Tests / acceptance

- Typed accessors return the correct type and raise on mismatch.
- `Json.to_struct(T, Json.from_struct(v)) == v` round-trips for a sample struct
  with nested arrays/objects/scalars.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- `JSON::Serializable` types must be declared per application; this does not
  give inference — it restores *explicit* typed boundaries, not chord's
  compile-time generic propagation.
- `to_json`/`from_json` round-trips carry a small overhead; these are opt-in
  conveniences, not a change to the hot `JSON::Any` path.
- Full `Track(T)`/`Draft(T)` generics remain a non-goal here; do not silently
  imply this plan delivers them.
