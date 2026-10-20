# 03 — Copy-on-write / structural-sharing applier (optional)

## Objective

Add an optional immutable applier that shares unchanged subtrees with its
inputs (copy-on-write), matching chord's `applyImmutable`/`applyImmutableBatches`
and `applyImmutableTrusted` performance characteristics, without changing the
existing safe deep-copy default.

## Current behavior

`src/llm/chord/delta/apply.cr`:

- `apply_immutable` (line 7) and `apply_immutable_batches` (line 11) start from
  `Json.deep_copy(target)` and then run `apply_ops`, which **deep-copies every
  payload** (`Op::Replace` → `Json.deep_copy(op.value)` at line 24; `Splice`
  items and `Set` values similarly). The result is fully independent of both
  inputs — safe, but O(tree) with no structural sharing.
- `apply` (line 3) mutates `target` in place and also deep-copies payloads.

chord instead: `apply` **adopts** payload containers (no copy), and
`applyImmutable`/`applyImmutableTrusted` copy only the containers along each
op's path (`copyContainers`, `index.ts:475`; `copyPath`,
`apply-immutable-trusted.ts:63`), sharing the rest.

## Key constraint: value struct, reference containers

`JSON::Any` is a value struct but wraps reference types (`Hash`, `Array`).
Copying a `JSON::Any` copies the reference, not the container. So structural
sharing is expressible: a copy-on-write applier copies the `JSON::Any` wrappers
along the path and reassigns container references, leaving untouched subtrees
aliased.

## Target behavior

Add two functions, leaving the existing ones untouched:

- `apply_immutable_shared(target, ops) : JSON::Any` — copy-on-write: shares
  unchanged containers with `target` and adopts op payload containers (no
  `Json.deep_copy` of payloads).
- `apply_immutable_batches_shared(target, batches) : JSON::Any` — same, one
  copy-on-write scope across all batches; no intermediate revision is exposed
  (chord documents this in `index.ts:413`).

Do **not** change `apply`/`apply_immutable`/`apply_immutable_batches` semantics.

## Steps

1. Port `copyContainers` (index.ts:475) into `apply.cr` as a private
   `copy_containers(root : JSON::Any, path : Path, owned : Set(JSON::Any))`.
   Crystal notes:
   - Use a `Set(JSON::Any)` (equality-based) in place of `WeakSet` — there is no
     GC-keyed identity set for value structs. Because `JSON::Any#hash` is
     content-based, two equal containers collapse to one entry; this is safe
     here because the set is only used to avoid copying a container twice along
     one path, and content-equality implies same shape. Confirm this reasoning in
     the plan's notes and add a test that exercises equal-sibling subtrees.
   - Shallow-copy `Hash`/`Array` via `.dup` (or `Hash(String, JSON::Any).new`
     copy) and reassign through the parent.
2. Port `appendCopy` (index.ts:448) — the `concat` fast path for an append at
   the end of a not-yet-copied array — or skip it in the first iteration and
   note it as a follow-up.
3. Implement `apply_immutable_shared` by iterating ops: for `r`, set
   `root = op.value` (adopt, no copy); otherwise copy the path's containers and
   reuse the existing `apply_ops` on a single op (or inline the leaf writes to
   avoid re-validation).
4. `apply_immutable_batches_shared` wraps the same scope across batches.
5. Add `PathError`/`UnsafePathError` behavior identical to the current appliers:
   `copy_containers` raises `PathError` when a segment is missing or a non-object
   is traversed.

## Affected files

- `src/llm/chord/delta/apply.cr`.
- `spec/apply_spec.cr`.

## Tests / acceptance

- Same-value contract: `apply_immutable_shared(base, ops) == apply_immutable(base, ops)` for a corpus of random bases and op batches.
- Aliasing contract (documented, deliberate): mutating an op payload after the
  call is visible in the result; mutating an untouched subtree of `base` is
  visible in the result. Assert this to lock in the sharing semantics.
- `apply_immutable_batches_shared(base, [b1, b2]) == apply_immutable_batches(base, [b1, b2])`.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- This **changes the safety model for the new functions only**: results alias
  inputs. Callers must not mutate shared containers. Keep the safe deep-copy
  versions as the default; document the shared variants as a perf escape hatch.
- `Set(JSON::Any)` with content-based equality is a substitute for `WeakSet`,
  not a drop-in. The "copied once per path" invariant still holds for distinct
  containers along a single path; equal-but-distinct containers are an edge case
  to cover in tests.
- This is optional; adopt only if profiling shows `apply` cost matters.
