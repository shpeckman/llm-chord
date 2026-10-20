# 05 — UTF-16 code-unit semantics for `t`/`a`/`overlap`

## Objective

Make string truncation counts interoperate with chord by counting **UTF-16 code
units** (chord's unit), not Crystal **code points**. Today a `t` op emitted by
llm-chord carries a code-point count, so a chord replica truncating the same
string by that many UTF-16 units diverges on astral characters (e.g. emoji).

## Current behavior

- `src/llm/chord/delta/diff.cr` `emit_string` (line 60) computes
  `before.size - shared` where `size` is code points, and emits
  `Op::Truncate.new(path, before.size - shared)`.
- `src/llm/chord/delta/apply.cr` `apply_leaf` `Truncate` branch (line 63) does
  `current[count, current.size - count]` — `count` is treated as a **code-point**
  index.
- `src/llm/chord/delta/overlap.cr` returns a code-point count (`tail.index`,
  `tail[k, n]`, `b[0, n]` all index by code point).

chord's `t` count is UTF-16 code units (`current.slice(op[2])`), and `overlap`
returns UTF-16 code units.

## Key facts about Crystal strings

- `String#size`/`#[](index)`/`#[](start, count)` index by **code point**, O(n)
  per access (UTF-8 scan). `String#bytesize` is bytes.
- `String#each_char` yields `Char`; `Char#ord` is the code point.
- Code points `>= 0x10000` (non-BMP) are 2 UTF-16 code units; everything else
  is 1 unit. A shared prefix/suffix boundary is always a code-point boundary,
  so converting a code-point overlap count to UTF-16 units is exact.

## Target behavior

All **wire-visible** string counts (`t` count, and `overlap`'s public return)
are UTF-16 code units, matching chord. Internal `a` text is carried verbatim
(no count), so it is unaffected.

## Steps

1. Add a private helper module (new file `src/llm/chord/delta/utf16.cr`, or a
   `private` section in `overlap.cr`) with:
   - `utf16_size(s : String) : Int32` — sum `ord >= 0x10000 ? 2 : 1` over `each_char`.
   - `utf16_slice(s : String, from_units : Int32) : String` — walk `each_char`,
     accumulate units, return the substring starting at the first char whose
     unit index >= `from_units`; raise if `from_units` is not a code-point
     boundary (defensive).
2. `overlap.cr`: keep the code-point probing internally (it is correct and
   native), but convert the returned count to UTF-16 units via
   `utf16_size(b[0, n])` (or `utf16_size(a[tail ...])`) before returning. Update
   the doc/README note that `overlap` returns UTF-16 code units.
3. `diff.cr` `emit_string`: compute the truncate count as
   `utf16_size(before) - shared` (where `shared` is now in units) and emit that
   as `Op::Truncate`'s count. The append remainder stays a code-point slice from
   the boundary `shared` — keep a separate code-point boundary variable so units
   and code points are never mixed.
4. `apply.cr` `Truncate` branch: interpret `op.count` as UTF-16 units — use
   `utf16_slice(current, op.count)` to produce the truncated string (drop the
   current `Math.min` clamp, since `utf16_slice` handles over-length by
   returning `""`).
5. `codec.cr`: no change — `t`'s count is an opaque integer on the wire.

## Affected files

- `src/llm/chord/delta/utf16.cr` (new) or `overlap.cr` (if inlined).
- `src/llm/chord/delta/overlap.cr`
- `src/llm/chord/delta/diff.cr`
- `src/llm/chord/delta/apply.cr`
- `spec/overlap_spec.cr`, `spec/diff_spec.cr`, `spec/apply_spec.cr`
- `README.md` (overlap return-unit note).

## Tests / acceptance

- `spec/overlap_spec.cr`: a string ending in an astral char returns a UTF-16
  unit count, and the count equals `utf16_size(shared_prefix)`.
- `spec/diff_spec.cr`: diffing `"a😀"` vs `"a😀b"` (append) emits `a` with text
  `"b"`; diffing `"😀x"` vs `"x"` emits `t` with count 2 (the emoji is 2 units).
- `spec/apply_spec.cr`: applying `t` with count 2 to `"😀x"` yields `"x"`; the
  round-trip `apply_immutable(before, diff_revisions(before, after)) == after`
  holds for strings with astral chars.
- Run `crystal spec` and `ameba`.

## Risks / trade-offs

- `utf16_size`/`utf16_slice` are O(n) scans; string ops are already O(n) in
  Crystal, and this only touches strings with non-BMP characters in practice
  (ASCII is 1 unit per code point, so the fast path is `utf16_size == size`).
- This is a **breaking wire-format fix** for `t` counts on astral strings:
  previously-emitted `t` ops are interpreted differently after the change.
  Flag this in the plan/CHANGELOG; it is required for cross-replica convergence.
