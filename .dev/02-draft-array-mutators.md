# 02 — Array/object mutation surface on `Draft`

## Objective

Give `Draft` (`src/llm/chord/delta/draft.cr`) the mutation surface chord's
overlay draft exposes for arrays and objects, so callers can edit a change the
way they would in TypeScript.

## Current behavior

`Draft` (74 lines) wraps a `JSON::Any` and exposes only:

- `[](key : String)`, `[]?(key : String)`, `[](index : Int)`
- `[]=(key : String, value)`, `[]=(index : Int, value)`
- `<<(value)` (array append)
- `as_s/as_i/as_f/as_bool/as_a/as_h/null?`

Missing versus chord (`packages/chord/src/delta/tracker.ts`, `arrayMutators`
at line 1177): `push`, `pop`, `shift`, `unshift`, `splice`, `reverse`, `sort`,
`fill`, `copyWithin`; object key `delete`; `length` grow/shrink (null fill).

The `Draft` struct is **re-fetched** from `Change#state` on every access
(`tracker.cr:32–35` constructs a fresh `Draft.new(@state)`), so the struct has
no identity to preserve — mutations must act on the shared underlying
`JSON::Any#raw` containers, which they already do.

## Target behavior

Add, to `Draft`, in the same value-converting style as the existing setters
(`Json.to_any`):

Object:

- `delete(key : String) : Nil` — remove a key; no-op semantics follow
  `Hash#delete` (return removed value or nil optional).

Array (returning/accepting `JSON::Any` or converted values via `Json.to_any`):

- `push(*values)` / `push(values : Array)` — append, return new size.
- `pop : JSON::Any?`
- `shift : JSON::Any?`
- `unshift(*values)` — prepend, return new size.
- `delete_at(index : Int) : JSON::Any` — remove by index.
- `size : Int32`, `empty? : Bool` (array).
- `reverse : Draft` and `reverse! : Draft` (in place).
- `sort! : Draft` and `sort!(&block)` (in place, with comparator returning `Int32`).

`length` grow/shrink is folded into the setter rules rather than exposed as
a bare `length=` — see below.

## Steps

1. Add a private helper on `Draft` (or reuse `Json`) to convert arbitrary
   values: the existing `[]=` already does `raw[key] = Json.to_any(value)`;
   mirror that for each new method so non-`JSON::Any` inputs are accepted
   (structs, hashes, arrays, scalars) through the `to_json` round-trip.
2. Implement the array methods as direct `Array(JSON::Any)` operations on
   `@value.raw.as(Array)` with `Json.to_any` on inputs. Raise the same
   `Exception.new("Draft is not an array")` message as the current accessors on
   type mismatch.
3. `splice(index, remove, *items)` port the index/remove semantics of
   `Array#[](start, count) = replacement` in Crystal (the built-in slice-assign
   already matches JS splice for non-negative indices).
4. Grow/shrink:
   - `[]=(index, value)` already appends when `index == raw.size` (Crystal array
     assignment semantics); keep it.
   - Add `Draft#[]=(index, nil)` or a dedicated `Draft#truncate_to(n)` only if a
     concrete consumer needs it — do not invent a `length=` setter, since
     chord's `arr.length = n` maps to grow-with-`null`/shrink and Crystal has no
     property-setter hook. Prefer explicit `truncate(n)` / `pad(n)` methods.
5. `sort!` accepts an optional block `(a : JSON::Any, b : JSON::Any) -> Int32`
   for custom ordering; default is Crystal's `<=>` on `JSON::Any` (which
   compares raw values).
6. Update the `Draft` doc examples in `README.md` and the public API list
   (`README.md:122–138`) to mention the new methods.

## Affected files

- `src/llm/chord/delta/draft.cr` (primary).
- `spec/draft_spec.cr` (tests).
- `README.md` (API reference — only if the public list is kept in sync).

## Tests / acceptance

- Extend `spec/draft_spec.cr`:
  - `push/pop/shift/unshift/splice/delete_at/reverse/sort!` produce the same
    `JSON::Any` as the equivalent Crystal array operations.
  - Object `delete` removes the key and is observable via `prepared.value`.
  - Each mutator feeds through `Change#prepare` correctly: mutating a draft then
    preparing yields ops that, when applied, equal the mutated value.
  - Type-mismatch methods raise on a non-array/object draft.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- `Draft` is a value struct over a mutable shared `JSON::Any`; there is no
  stale-handle tracking. This is unchanged from today — the plan only widens the
  method surface, not the lifetime contract.
- `Json.to_any` round-trips through `to_json`, so input values must be
  JSON-serializable (already the rule for `[]=`/`<<`).
- Full chord parity (proxy-based overlay, `fill`/`copyWithin`, `undefined`
  rules) is out of scope here; those need the overlay design, not the clone+diff
  model. This plan adds the ergonomic surface that clone+diff can support.
