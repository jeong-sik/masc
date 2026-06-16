# RFC-0249: Remove the dead `stale_factor` field (execute RFC-0239/0243/0244/0247)

## §0 Summary

`stale_factor` is a `float` field on the memory-OS `fact` record that no producer
ever writes as non-zero: both producers (`keeper_librarian.ml`,
`keeper_memory_os_consolidator.ml`) hardcode `0.0` at creation, and nothing updates
it thereafter. Its sole consumer, `stale_penalty = 1.0 -. clamp01 fact.stale_factor`,
is therefore a constant `1.0` multiplicative no-op in `score_fact`. The field is also
rendered to the model as `stale=0.00`, falsely signalling "fresh" on facts of any age.

This RFC removes the field, the `stale_penalty` function, and the render output.
Scoring is byte-unchanged (the factor was ×1.0). The staleness signal the field
pretended to provide is already delivered by `truth_recency_factor` (lifetime-adjusted
age decay via `expected_lifetime_cycles`) and the `valid_until` hard-TTL GC, both
now live (the latter wired in `server_bootstrap_maintenance.ml`).

This executes the removal prescribed by four prior RFCs and closes the last dead
field left behind when RFC-0247 §2.3 revived `valid_until` / `expected_lifetime_cycles`.

## §1 Motivation (falsified on `origin/main` 1037b9a16)

- RFC-0239 §table (line 237): `stale_factor` is a **Symptom** — "penalizes stale
  facts in score ... Absorb into R1 (set lifetime at write); close".
- RFC-0243 §1 (line 45): the issue table records `stale_penalty ≡ 1`, and §6
  (line 151) prescribes **Dead-field removal** (`stale_factor`, `expected_lifetime_cycles`).
- RFC-0244 (line 126): references that the recall render "was written to remove
  (`stale_factor` / ...)" — the recall-side removal already landed (the render now
  uses `humanize_age`), but the stored field remained.
- RFC-0247 §2.3 (line 66): marks `stale_factor : float (* always 0.0 — dead *)` and
  revived `valid_until` / `expected_lifetime_cycles` via `category_valid_until` /
  `category_lifetime_cycles`, but left `stale_factor` behind.

`git log -S stale_factor` traces it to `8fb955bbb` (#21195 "Improve Memory OS stale
fact lifecycle") — an intended feature whose producer was never implemented.

On current main, `rg stale_factor lib/keeper` shows: the record field
(`keeper_memory_os_types.ml`), its codec encode/decode, `stale_penalty`
(`keeper_memory_os_policy.ml`), the two `= 0.0` producer sites, and the (now-historical)
recall comment. No non-zero write exists. (`dashboard_cache.ml`'s `stale_factor = 3.0`
is an unrelated TTL-grace multiplier and is not touched.)

## §2 Design

Remove, in one PR:

1. The `stale_factor : float` field from the `fact` record
   (`keeper_memory_os_types.ml`) and its `.mli`.
2. The `stale_factor` encode (`fact_to_json`) and decode (`fact_of_json`) codec
   entries. Decode was the only non-trivial site (legacy `clamp01` default); removal
   is backward-compatible — old JSON carrying `"stale_factor"` is silently ignored
   on read (the codec does not reject unknown keys), so existing on-disk facts load
   unchanged. No schema-version bump or migration script is required.
3. The `stale_penalty` function (`keeper_memory_os_policy.ml`) and its `val` in the
   `.mli`; remove the `*. stale_penalty fact` factor from `score_fact`.

`clamp01` is retained (still used by confidence clamping in `fact_of_json` and the
reaffirm-weight blend in `keeper_memory_os_policy.ml`).

Scoring after removal: `score_fact = confidence × recency × truth_recency × access ×
lexical_relevance` — byte-identical to before (the removed factor was ×1.0).

## §3 Verification

- `dune build` + `@check`: exit 0.
- ocamlformat `@fmt`: clean.
- `test_keeper_memory_os`: 69/69. The GC test's `explicit_stale` (which set
  `stale_factor = 1.0` to exercise the verdict-discard path) is re-grounded as
  `low_confidence` (`confidence = 0.0`) — same score-zero → verdict-discard outcome,
  preserving coverage of the discard path via a still-valid mechanism. Obsolete
  assertions (codec round-trip of `stale_factor`, default-stale, stale-zeros-score)
  are removed.

## §4 Non-goals

- No change to `truth_recency_factor`, `valid_until` GC, or the recall `humanize_age`
  render — these already deliver the staleness signal.
- No migration script: the codec ignores the dropped key on read.
- The dashboard `stale_factor` (TTL grace) is a separate concept and is untouched.
