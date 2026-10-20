# 04 — Strict-JSON validator + op/wire-op shape validation

## Objective

Add the validation chord performs in `revision-validator.ts` and
`index.ts` (`assertValidOp`/`assertValidWireOp`) so untrusted roots and
op tuples are rejected at the boundary, matching chord's safety posture.

## Current behavior

- `src/llm/chord/json.cr` has `valid?` (line 30) which only checks finite
  `Float64` recursively — `JSON::Any` cannot represent cycles, sparse arrays,
  symbols, accessors, or `undefined`, so most chord validation has no analog.
- `src/llm/chord/delta/types.cr` has `assert_safe_path` (line 105) for reserved
  segments and negative indices only.
- `src/llm/chord/delta/codec.cr` `Decoder#decode`/`decode_op` do minimal shape
  checks (arity for `#`/`r`, int coercion); `apply.cr` skips shape validation
  because ops are typed structs.

Reference: chord `assertValidOp` (`index.ts:152`), `assertValidWireOp`
(`index.ts:211`), `assertPermutation` (`index.ts:199`), `assertIndexInRange`
(`index.ts:304`), `JsonRevisionValidator` (`revision-validator.ts:8`).

## Target behavior

1. **Op-shape validation for the codec boundary.** Add a private
   `assert_valid_wire_op(arr : Array(JSON::Any))` in `Decoder`, porting
   `assertValidWireOp`'s per-verb arity/shape/permutation checks, and call it at
   the top of the loop in `decode`. This is the meaningful gap — decoded wire is
   untrusted and today malformed tuples can throw confusing `IndexError`/cast
   errors instead of a clear error.
2. **Permutation bijection check.** Add `assert_permutation(values : Array(Int32))`
   (port of `assertPermutation`) and call it in `Decoder` for `m` and in
   `apply`'s `Op::Move` branch before mutating.
3. **Index-in-range guard.** In `apply.cr`, `write!` already raises
   `UnsafePathError` when `key > raw.size` (line 109); confirm this matches
   chord's `assertIndexInRange` (index > length throws) and add a focused test.
4. **Strict-JSON root validator.** Add `Json.validate!(value : JSON::Any) : JSON::Any`
   (or `Json.strict?`) that walks the tree and rejects non-finite `Float64` —
   the only strict-JSON violation `JSON::Any` can carry. (Cycles, sparse arrays,
   and non-data properties are impossible by construction.) Expose it for
   callers to run at their ingestion boundary, mirroring `copyJson`/`isJsonValue`.

## Steps

1. In `types.cr`: add `assert_permutation` (private or module-level).
2. In `codec.cr`: add `assert_valid_wire_op`, called from `decode`; add
   `assert_permutation` for `m`; keep `int`/`parse_path` but tighten integer
   handling to reject non-`Int64` path ids with a clear message.
3. In `apply.cr`: call `assert_permutation` in the `Op::Move` branch (line 32);
   add a test for `write!`'s index guard.
4. In `json.cr`: add `validate!` (raises) / `strict?` (bool) for finite-float
   enforcement; have `valid?` delegate to the recursive walk.
5. Document the new validators in `README.md` API list.

## Affected files

- `src/llm/chord/delta/types.cr`
- `src/llm/chord/delta/codec.cr`
- `src/llm/chord/delta/apply.cr`
- `src/llm/chord/json.cr`
- `spec/codec_spec.cr`, `spec/apply_spec.cr`, `spec/json_spec.cr`
- `README.md`

## Tests / acceptance

- `spec/codec_spec.cr`: malformed wire tuples (bad arity, non-bijection `m`,
  non-integer path id, `s` with a string path) raise a clear error; valid wire
  still round-trips.
- `spec/apply_spec.cr`: a non-bijection `Op::Move` raises before mutating.
- `spec/json_spec.cr`: `validate!` raises on a non-finite float anywhere in the
  tree; `strict?` returns false for the same.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- `assertValidOp` (decoded `Op` tuples) has no direct equivalent since Crystal
  uses typed structs — only the wire decoder needs it. This is intentional and
  noted; do not add tuple-shape checks to `apply`.
- Validation adds a per-op cost at decode time; keep it O(op length) and avoid
  re-walking payloads beyond what is needed.
