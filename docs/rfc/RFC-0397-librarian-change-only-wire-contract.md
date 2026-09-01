---
rfc: "0397"
status: Draft
---

# RFC-0397 — Librarian wire contract states changes, not the whole roster

- Status: Draft
- Decision driver: issue #31627. Across 517 recorded `domain_output_invalid` rejections, 513 (99%) are list-keeping mistakes — a wrong id, a missing id, a repeated id — not a wrong judgement about what to remember. The 2026-08-23 pair (#29561 short surrogate ids, #29579 digest removal from recall lines) removed the id-transcription trap and the failure class moved rather than disappeared: `unknown_retained_memory_id` stopped on 08-23, `duplicate_selected_memory_id` started on 08-25 and reached 29 on 08-29, the highest single-day count since the switch. This RFC removes the roster transcription itself.
- Area: `lib/keeper/keeper_librarian.ml` (`materialize_facts` retain/validate_dropped/append_new, `parse_error`), `lib/keeper/keeper_librarian_runtime.ml:722` (`failed_output`), `config/prompts/librarian.md`, `docs/spec/12-memory-systems.md` (Write Contract), `test/test_keeper_librarian_retry.ml`.

## Problem (audited)

Measured from `<base>/.masc/keepers/*.memory-journal.jsonl` and `<base>/.masc/exact-lane-runs-v5.jsonl` on 2026-08-29 14:39.

1. **The failures are clerical, not editorial.**

   ```
   unknown_retained_memory_id      423   (421 of them: the model wrote sha256:… where m<N> was required)
   unknown_dropped_memory_id        47
   duplicate_selected_memory_id     33
   missing_disposition               8
   dropped_memory_id_also_retained   2
   unexpected_field / duplicate_field 4
   ```

   Not one rejection records a disputed retention judgement. Every one records the model failing to carry a list across the wire correctly.

2. **The last fix moved the failure instead of ending it.**

   ```
   08-21  unknown_retained  87
   08-22  unknown_retained 112
   08-23  unknown_retained  90    <- #29561, #29579 land
   08-24  none
   08-25  duplicate_selected   1
   08-26  duplicate_selected   4
   08-28  duplicate_selected   9
   08-29  duplicate_selected  29
   ```

   Blocking the digest copy did not reduce the bookkeeping burden; it changed which part of the bookkeeping the model gets wrong. On 08-29 the lane failed 11 times in one hour (40 runs, 27%).

3. **A clerical slip costs an editorial pass.** `materialize_facts` returns `Error` for the whole selection, so the snapshot is not written, every correct disposition in that pass is discarded, and `cadence_record_attempt` defers the next attempt by the full cadence (default 3 turns). By then the bounded conversation slice may no longer contain the evidence for the new claims that pass had extracted. Fail-closed is not preserving truth here; it is dropping curation work.

4. **The rejection destroys the evidence needed to classify it.** `keeper_librarian_runtime.ml:722` binds `failed_output` to an empty JSON object. All 20 duplicate rejections in the run registry carry `"output": {}`. The operator sees a bare digest — resolving it to a claim required hashing all 83 snapshot facts by hand.

5. **The transcription carries no information.** Listing an existing id under `retained_memory_ids` restates what the snapshot already says. It is the largest part of the output by volume, zero by content, and the sole source of failure classes 1, 4 and 5 above.

### Why the current shape exists

`keeper_librarian.ml:373` states it: *"Silent omission is no longer the deletion operation; it is a contract violation."* Under set semantics a truncated or lazy answer deleted memories with no record. That risk is real. The response — demand a complete roster every pass — inverted the safe failure direction: a truncated answer now destroys the pass instead of forgetting less.

## Decision

- **D1 — the wire contract states changes only.** The librarian returns `dropped` (memory id + one-sentence reason) and `new_claims`. `retained_memory_ids` is removed. A current fact not named in `dropped` is retained. Omission is retention, so a truncated answer forgets less and never deletes silently — the failure mode the totality rule was introduced to catch becomes unrepresentable rather than detected.

- **D2 — a new claim whose identity already exists is already remembered, not an error.** `memory_id` is the SHA-256 of the exact claim bytes, so an identical claim denotes the same memory. Adding a member to a set that contains it is a no-op; the resulting snapshot is byte-identical either way. This is not deduplication as damage control — it is the identity relation the schema already declares (`docs/spec/12-memory-systems.md`, Write Contract). The stored fact keeps its original `first_seen`; the restated claim contributes nothing to drop.

- **D3 — dropping a memory and restating it in the same pass stays an explicit error, under its own name.** `Dropped_memory_id_recreated` replaces the overloaded `Duplicate_selected_memory_id`. Here the two readings — forget it, remember it — produce opposite snapshots, so no silent resolution is admissible. Keeping it typed and separate is what makes D2 safe to relax: the benign shapes stop consuming passes while the one genuine contradiction stays loud and countable.

- **D4 — a failed pass records the model's output.** `failed_output` carries the parsed JSON the lane received. Without it, no future decision about this contract can be evidence-based, and the operator cannot see which memory a rejection names. The failure detail additionally carries the first 80 bytes of the offending claim alongside the digest.

- **D5 — re-evaluation of stored memories becomes its own pass.** `config/prompts/librarian.md` currently asks the model to re-judge every stored memory on every pass, which the roster transcription was the mechanism for. Under D1 that mechanism is gone. Re-judging moves to a prune pass that receives the full roster and returns only `dropped`. Ordinary passes stop paying for it. This RFC does not decide what starts that pass.

- **D6 — hard cut.** No reader accepts the old three-field shape, no converter, no migration. A snapshot is claim text plus category plus timestamp and is unaffected by the wire change, so fresh-state contract applies to the wire only.

## What this removes

Deleted from the `parse_error` type, i.e. made unrepresentable rather than handled:

| Constructor | Recorded failures | Why it cannot occur |
|---|---|---|
| `Unknown_retained_memory_id` | 423 | no retained ids are transmitted |
| `Missing_disposition` | 8 | omission is a disposition |
| `Dropped_memory_id_also_retained` | 2 | there is no retained list to contradict |
| `Duplicate_retained_memory_id` | 0 | same |

`Duplicate_selected_memory_id` (33) splits: the retained-collision and new-claim-collision shapes become no-ops under D2; the dropped-collision shape becomes `Dropped_memory_id_recreated`.

`Unknown_dropped_memory_id` (47) survives — a drop must still name its target. Its error surface shrinks from the full roster to the few ids actually dropped.

## Trade-off

Retention becomes free, so a lazy pass grows the store. The counter-pressure is D5 plus the existing recall budget, and the failure is now visible growth rather than silent loss. The honest cost: between budget-triggered prunes, a memory that no longer earns its place can sit in the store longer than it does today. That is accepted here as the cheaper side — today's mechanism buys prompt re-evaluation at 513 discarded passes.

## Verification

1. `parse_error` loses four constructors; every match site becomes exhaustive against the smaller type. The compiler, not a test, proves classes 1, 4 and 5 gone.
2. `test/test_keeper_librarian_retry.ml` — `test_new_claim_cannot_collide_with_retained_identity` (:234) inverts to assert the pass succeeds and the snapshot is unchanged; `test_new_claim_cannot_recreate_dropped_current_identity` (:249) keeps rejecting, now expecting `Dropped_memory_id_recreated`; `test_totality_rejects_unaccounted_current_id` is deleted with the rule.
3. New test: a pass naming no drops and no new claims leaves the snapshot byte-identical.
4. Live: `domain_output_invalid` in the keeper journals over a week after merge, against the 08-25..08-29 baseline (1, 4, 1, 9, 29). Also counted: snapshot fact growth per keeper, which D5 is answerable for.
