---
rfc: "0247"
extends: "0247"
title: "Memory OS purge + LLM-judgment rebuild — implementation plan (phase of RFC-0247)"
status: Draft
created: 2026-06-16
updated: 2026-06-18
---

# IMPLEMENTATION PLAN — Purge the score-based Memory OS, rebuild summarize/forget/update as LLM judgment

> Phase document of [RFC-0247](RFC-0247-memory-os-associative-graph-forgetting-brain.md). File-level purge+replace plan for removing score-based Memory OS and rebuilding summarize/forget/update as LLM judgment.
>
> Constraint carried from source review: `fact_of_json` (codec) requires `confidence` to be `Some` — the `(Some _, None, _, _) -> None` arm drops the row entirely. The codec migration must make `confidence` decode-optional, or the 6462 existing rows vanish.

Worktree: `/Users/dancer/me/workspace/yousleepwhen/masc/.worktrees/rfc-0246-keeper-brain-memory`. All file:line refs verified against source I opened. Strict-reviewer stance applied throughout: **no step may compute a keep/forget/promote decision from a number, and no step may classify a claim by substring.**

A correction the four reports converged on, restated as a hard constraint for the implementer: **`run_gc` is NOT 0-callers.** It is wired at `server_bootstrap_maintenance.ml:147`, env-gated OFF (`MASC_KEEPER_MEMORY_OS_GC` default false, `:130-133`). And the live hot-path forgetting is **only** the `score_fact`-ranked cap at `keeper_librarian_runtime.ml:281`/`io.ml:483-486` — GC being off means if you delete `score_fact` without replacing that `~rank`, the per-turn write path loses its only drop criterion. Sequencing below handles this.

---

## 1. PURGE

### 1a. Safe to delete NOW (fan-in 0, confirmed)
- `keeper_memory_os_policy.ml:127-138` `score_tool_result` (+ `.mli:50`). Zero callers.
- `keeper_memory_os_policy.ml:162-175` `bump_access_for_turn` (+ `.mli:66`), and its sole helper `string_contains` (`policy.ml:140-151`) once `bump_access_for_turn` is gone (verify `string_contains` has no other caller before removing — it likely doesn't, but `rg string_contains lib/` first). Explicitly not wired into recall (`policy.ml:158-159`).

These two compile-clean on removal with no consumer change.

### 1b. Delete AFTER redirecting their consumer (the scoring core)
These are all reachable only through `score_fact` or the GC/consolidator verdict; each line below names the consumer that must change first (covered in §2/§4).

- `score_fact` (`policy.ml:108-121`, `.mli`). Consumers to redirect first: `recall.ml:146,162` (render), `gc.ml:82` via `decide_retention`, `keeper_librarian_runtime.ml:281` (`~rank`).
- `decide_retention` + `retention_verdict`/`KeepVerbatim`/`Discard` + `default_discard_score_threshold` (`policy.ml:15-20,123-125`). Consumer: `gc.ml:54-58` (replaced wholesale, §2-FORGET).
- `truth_recency_factor`, `truth_anchor`, `truth_lambda_for_fact`, `default_truth_lambda`, `default_cycle_seconds` (`policy.ml:12-13,42-58`). Fan-in 1 → `score_fact`. (`truth_anchor`'s *logic* moves to recall's `staleness_marker`, which already independently re-derives the anchor at `recall.ml:130-134` — so nothing recall needs is lost.)
- `stale_penalty` (`policy.ml:38-40`). Fan-in 1 → `score_fact`. Already a constant `1.0` (every producer writes `stale_factor=0.0`), so deletion is behaviorally inert.
- `recency_factor`, `access_factor`, `default_lambda`, `default_alpha`, `default_max_access_factor` (`policy.ml:10-11,14,23-31`). Fan-in only inside `score_fact`.
- `blend_confidence`, `reaffirm_weight` (`policy.ml:184-192`). Consumer: `reobserve_fact` body (§4-UPDATE rewrites it to drop the confidence blend; the function `reobserve_fact` itself survives as the merge callback but stops touching confidence).
- `lexical_relevance` / `default_relevance_gain` (`policy.ml:78-106`): fan-in only inside `score_fact`. **KEEP `tokenize`** (`policy.ml:60-76`) — it is the SSOT token splitter and will be reused by the judgment recall/consolidation seed-matching as a *retrieval pre-filter input*, not a score (see Risk R3). Deleting `tokenize` is optional and can wait; deleting `lexical_relevance` is required.

### 1c. Consolidator scoring (delete with §2-SUMMARIZE rewrite)
- `noisy_or` (`consolidator.ml:46-47`), `default_confidence_threshold=0.5` (`:35`), confidence floor in `eligible` (`:62-63`), confidence-keyed `representative` primary sort (`:71`), `noisy_or` recompute (`:116`). **KEEP**: `normalize_claim` grouping, `is_promotable` gate, `>= min_keepers` distinct-count rule, `observed_by` provenance, deterministic output order. The count rule (`>= 2` keepers) is a *provenance fact*, not a score — it is allowed to stay as a pre-filter that decides which claims the LLM summarize pass even looks at (Risk R1).

### 1d. Schema field purge + codec migration for the 6462 existing rows
The field removals from the `fact` record (`types.ml:100-120`) and their codec handling:

- **`confidence`** — REMOVE from the record. Migration is mandatory and non-trivial: `fact_of_json` currently **requires** it (`types.ml:275`, and `(Some _, None, _, _) -> None` at `:329` drops any row missing it). Change: stop reading `confidence` into the record; on decode, *ignore* a present `"confidence"` key (old rows have it) and never require it. On encode, stop emitting it (`types.ml:249`). Old rows still parse because the required tuple drops to `(claim, category, source)`.
- **`stale_factor`** — REMOVE from record; drop encode (`:255`) and the decode block (`:289-296`). Already inert.
- **`expected_lifetime_cycles`** — REMOVE from record; drop encode (`:260`) and decode (`:302-306`). Dead once `truth_lambda_for_fact` is gone.
- **`access_count`** — REMOVE from record (it only ever fed `access_factor`). Drop encode (`:252`) and decode (`:283`). `reobserve_fact` stops incrementing it (§4).
- **`last_accessed`** — REMOVE from record (fed only `recency_factor`). Drop encode (`:254`) and decode (`:287`). **Caveat**: confirm no non-score reader — `recall.ml` staleness uses `last_verified_at`/`first_seen`, not `last_accessed`, so this is safe.
- **`valid_until`** — **KEEP.** Load-bearing beyond scoring: `recall.ml:92-96 fact_is_current`, dashboard current/expired counts (`server_dashboard_http_keeper_api.ml`), and the deterministic Ephemeral TTL. This is a *timestamp comparison*, not a score — allowed.
- **`last_verified_at`** — **KEEP.** Drives recall's `staleness_marker` (`recall.ml:129-143`) and is the UPDATE freshness signal. Not a score.
- **`first_seen`**, **`observed_by`**, **`source`**, **`claim`**, **`category`**, **`schema_version`** — KEEP.

**Migration discipline**: bump `schema_version` (`types.ml:7`) to e.g. `"rfc0248-v3"` as the clean signal that scoring fields are deprecated-on-read. Decode must tolerate-and-drop the four removed keys (they exist in all 6462 fleet rows). The 6462 rows live on the fleet under `.masc/config/keepers/*.facts.jsonl` — **not in this worktree** (`find` for `*facts.jsonl` is empty here), so this count is a fleet figure, not repo-verifiable; the migration must be proven by a round-trip test fixture that feeds a v2 row (with `confidence`/`stale_factor`/`access_count`/`last_accessed`/`expected_lifetime_cycles`) into `fact_of_json` and asserts it parses (not drops).

---

## 2. REPLACE — judgment-based mechanisms

### SUMMARIZE — LLM consolidation pass (replaces count/noisy-OR promotion)

**Where it lives**: the always-on consolidation fiber, `server_bootstrap_maintenance.ml:90-118` (300s cadence, cross-keeper read + atomic `_shared.facts.jsonl` rewrite, per-tick failures caught). Keep the fiber skeleton; replace the arithmetic body in `keeper_memory_os_consolidator.ml`.

**What it reads**: (orient) the keeper's current fact set + the shared store; (gather) facts written since the last consolidation tick. **What it writes**: the rewritten store(s). The LLM call reuses the existing librarian provider plumbing (`keeper_librarian_runtime.ml extract_with_provider`, `:245-255`).

**4 phases ported from Claude Code §8** (Map Report 4):
1. **Orient** — read existing facts so the pass *improves topic-facts rather than duplicating*. Anti-duplication read-before-write.
2. **Gather** — take recently-written facts. The structural pre-filters that SURVIVE: `normalize_claim` grouping and `>= min_keepers` distinct-keeper count decide *candidate groups* (which claims are even shown to the LLM); these are provenance facts, not scores.
3. **Consolidate (LLM judgment)** — the LLM merges near-duplicate facts in a group into one durable topic-fact, **rewrites relative→absolute dates**, and marks contradicted older facts for deletion. This is where differently-worded-same-meaning claims finally merge (today they never do). Output is the merged claim text + which source facts it supersedes.
4. **Prune/index** — keep the store bounded by a *judgment keep-decision* ("which facts are still load-bearing"), not `score_fact` truncation.

The promoted shared fact's `confidence`/`noisy_or` recompute is **deleted**; `observed_by` (distinct keeper set), `is_promotable`, and the stricter outcome-positive shared gate survive. Promotion eligibility moves from "`confidence >= 0.5` floor" to "`is_promotable` AND `is_outcome_positive_for_shared_promotion` AND the judgment pass chose to surface it cross-keeper." `is_outcome_positive_for_shared_promotion` is a temporary category proxy pending #22447 outcome-eval metadata.

### FORGET — delete-on-contradiction + ephemeral drop, by judgment (no TTL-decay verdict)

**Delete `gc.ml`'s score path**: `keep_by_verdict`/`decide_retention`/`score_fact <= 0.02` (`gc.ml:54-58`). 

**Two forgetting mechanisms remain, neither a score**:
1. **Contradiction-delete (judgment)** — inside the consolidation pass: when a newer fact contradicts an older one, the LLM removes the old fact *at source* (Claude Code "fix at source", §8 Phase 3). This is a semantic comparison = an LLM call, never `stale_factor` arithmetic.
2. **Ephemeral hard-TTL (structural, KEEP)** — `gc.ml:25-29 ttl_expired` reads `valid_until > now`. `valid_until` is set only for `Ephemeral` facts (`category_valid_until`, `types.ml:90-93`). This is a timestamp comparison gated by a *typed category*, not a score — it is the deterministic write-time admission/expiry the user's "parse don't validate" instinct wants, and it stays. The `Ephemeral` arm is the masc encoding of Claude Code's "ephemeral task details" exclusion, aggressively forgotten.

**Staleness becomes a read-time message, not a rank** (already true in this branch — `recall.ml staleness_marker:129-143` prints `[stale: unverified, seen Nd ago — verify]`). Removing `truth_recency_factor` from `score_fact` does not touch this; it independently re-derives the anchor. This is exactly Claude Code's `memoryFreshnessText` mechanism: age changes *trust*, not *retrieval rank*.

**The GC fiber** (`server_bootstrap_maintenance.ml:130-174`) is the home for a per-keeper judgment FORGET/UPDATE-reconcile pass. It is currently default-OFF. **Decision needed (Risk R2)**: with `score_fact` cap deleted from the hot path, either (a) the per-turn cap moves to a structural rule (keep-newest-by-`first_seen` within a bound, category-aware), or (b) forgetting shifts wholesale into the GC fiber which must then be turned ON. I recommend (a) for the hot path (structural keep-newest cap, no LLM on the turn path) + the GC/consolidation fiber for semantic contradiction-delete. Keeping an LLM call off the keeper turn hot path matches the "consolidation pass is off-hot-path" intent.

### UPDATE — claim merge / fix-at-source (no confidence blend)

**`reobserve_fact` (`policy.ml:203-210`) body rewrite**: drop `confidence = blend_confidence ...` (deleted) and `access_count + 1` (field removed). It keeps refreshing `last_verified_at = Some now` (the freshness/recency signal recall reads). The merge *machinery* survives untouched: `merge_episode_facts` keying on `normalize_claim` (`io.ml:434-460`), single atomic rewrite, "first row of each identity is merge target." The `~merge` callback signature in `io.ml` stays generic.

**Net**: today UPDATE = "same claim re-seen → nudge a float." After = "same claim re-seen → refresh `last_verified_at`." The *content* reconciliation (a *changed/contradicting* claim → supersede old text + write new) is net-new and lives in the consolidation/GC judgment pass (it cannot be a per-turn substring compare). Feed candidate-matching existing facts into the extraction prompt as the masc analogue of Claude Code's `{existingMemories manifest}` so the LLM decides merge / supersede / write-new — that decision is the judgment, not a count.

### SUCCESS / FAILURE capture (mirror Claude Code `feedback` type)

**Typed change** (`types.ml:30-38` + `.mli`): extend the closed `category` sum with two arms:
```
| Validated_approach   (* a win: an approach confirmed to work — reuse it *)
| Lesson               (* a failure recorded as improvement: X failed because <why>; do <Y> *)
```
The compiler then forces edits at every exhaustive match — exactly the no-silent-omission property:
- `category_to_string`/`category_of_string` (`types.ml:40-61`): add `"validated_approach"`/`"lesson"` tokens.
- `is_promotable` (`types.ml:70-73`): `Validated_approach | Lesson -> true` — a lesson learned by one keeper should reach others (this is the whole "기억을 뇌처럼" point). In the post-purge model "promotable" means "the judgment pass may surface this cross-keeper," and both qualify.
- `category_valid_until`/`category_lifetime_cycles` (`types.ml:90-98`): both arms → `None` (durable, never hard-expire). **Note**: these two functions survive the purge (they gate the *structural* Ephemeral TTL, not a score), so the new arms just need a `None` branch the compiler demands.

**Body carries Why + How-to-apply.** Two options:
- **(a) Prompt convention only (minimal, recommended first)**: instruct the LLM that a `lesson` claim is one sentence `"<X> failed because <Why>; do <Y> instead"` and a `validated_approach` is `"<X> worked; reuse when <Z>"`. No record-field change — `claim` is already a free single sentence rendered one line in recall.
- **(b) Typed sub-fields (principled upgrade, later)**: add `lesson_why`/`how_to_apply : string option` to the record. Stronger (parse-don't-validate) but touches both codecs + every `fact` literal in `test/test_keeper_memory_os.ml`. Defer unless structured display is wanted.

**Producer prompt** (`config/prompts/keeper.librarian.episode_extraction.md`): replace the durability-gate axis with the Claude Code success/failure symmetry + "surprising/non-obvious" filter:
1. Category criteria — add `validated_approach` and `lesson` bullets *before* the last-resort `fact`.
2. Add the **symmetric trigger** instruction (Claude Code §3 line 236, verbatim rationale): "Record from failure AND success — if you only save corrections you drift from approaches already validated and grow overly cautious. Corrections are loud; confirmations are quiet — watch for them."
3. A `lesson` claim MUST contain the corrective action (do Y / fix is Z), not just "X failed."
4. Update the JSON schema `category` enum to include the two tokens.

`terminal_marker` is a distractor — do NOT repurpose it (episode-level, untyped `string`, producer-hardcoded `None` at `keeper_librarian.ml:261`). Success/failure is claim-level and belongs on `category`.

---

## 3. TYPES — the `fact` record AFTER

```ocaml
type category =
  | Code_change | Fact | Preference | Blocker | Goal | Constraint
  | Ephemeral
  | Validated_approach          (* win — reuse *)
  | Lesson                      (* failure recorded as improvement *)
  | Unknown of string

type fact =
  { claim : string                       (* the knowledge / rule / lesson body *)
  ; category : category                  (* parse-once typed; the only control axis *)
  ; source : provenance_event
  ; observed_by : string list            (* Tier-2 cross-keeper provenance *)
  ; first_seen : float
  ; valid_until : float option           (* Ephemeral hard-TTL; timestamp compare, not a score *)
  ; last_verified_at : float option      (* freshness for staleness MESSAGE + UPDATE; not a score *)
  ; schema_version : string
  }
```
REMOVED: `confidence`, `access_count`, `last_accessed`, `stale_factor`, `expected_lifetime_cycles`. No float anywhere participates in a keep/forget/promote *decision* — `first_seen`/`valid_until`/`last_verified_at` are timestamps used for current-vs-expired (comparison) and for a worded staleness *message*, never multiplied into a rank.

(Option (b) would add `lesson_why`/`how_to_apply : string option`.)

---

## 4. PHASING — ordered, each step compiles, lowest-risk first

**Step 0 (no-risk, no behavior change)** — delete `score_tool_result` + `bump_access_for_turn` (+ `string_contains` if unreferenced) and their `.mli` exports. Fan-in 0. Compiles immediately. *Small blast radius.*

**Step 1 (structural hot-path cap — UNBLOCKS the score purge)** — replace the `~rank:(score_fact ~now)` at `keeper_librarian_runtime.ml:281` with a structural keep-newest comparator (by `first_seen`/`last_verified_at` desc, category-aware so `Ephemeral` is dropped first). The `~rank` param in `io.ml` is already a generic callback — only the call site changes. This removes the *only* live consumer of `score_fact` on the hot path **before** deleting it, so the per-turn write path keeps a drop criterion. *Medium blast radius — it changes which facts survive the cap; cover with a test asserting Ephemeral-dropped-first / newest-kept.*

**Step 2 (recall render)** — change `render_fact`/`render_shared_fact` (`recall.ml:145-176`) to stop printing `score=%.3f` and stop calling `score_fact`; keep `confidence` out of the line too (it's being removed). The staleness marker already exists and stays. Recall ranking becomes: structural pre-filter (`fact_is_current`) + the consolidation pass having already pruned; ordering by recency/`first_seen`. *Medium blast radius — changes the prompt text keepers read; this is the user-visible "no score" surface.*

**Step 3 (GC verdict → structural + judgment)** — in `gc.ml`, delete `keep_by_verdict`/`decide_retention` path; keep `ttl_expired` (Ephemeral hard-TTL) and `dedup_by_claim` but replace its `better_scored` winner (`gc.ml:43-52`) with `last_verified_at`-latest (already the secondary key). GC stays env-OFF for now; this just makes it score-free. *Small blast radius — module is dark by default.*

**Step 4 (delete the scoring core)** — now that Steps 1-3 removed every consumer, delete `score_fact`, `truth_*`, `stale_penalty`, `recency_factor`, `access_factor`, `lexical_relevance`, `decide_retention`/`retention_verdict`, `blend_confidence`/`reaffirm_weight` and their defaults from `policy.ml`/`.mli`. Rewrite `reobserve_fact` body to drop confidence-blend + access bump (keep `last_verified_at` refresh). *Medium blast radius — large deletion, but consumers already redirected; compiler proves completeness.*

**Step 5 (schema + codec migration)** — remove `confidence`/`stale_factor`/`access_count`/`last_accessed`/`expected_lifetime_cycles` from the record and codecs; make decode tolerate-and-drop those keys; bump `schema_version`. **BIG BLAST RADIUS** — touches `fact_to_json`/`fact_of_json` (`types.ml:246-332`) and every `fact` literal in `test/test_keeper_memory_os.ml`. Gate with a v2-row round-trip parse test (the 6462-row safety net). Do this as its own PR.

**Step 6 (SUCCESS/FAILURE category arms + prompt)** — add `Validated_approach`/`Lesson`, let the compiler drive the exhaustive-match edits, update the producer prompt. Option (a) prompt-only first. *Medium blast radius — touches every category match site, but the compiler enumerates them.*

**Step 7 (SUMMARIZE judgment pass)** — rewrite `consolidator.ml` body: delete `noisy_or`/floor/confidence-`representative`; keep `normalize_claim`/`is_promotable`/distinct-count pre-filters; add the 4-phase LLM consolidation reading recent facts and writing merged topic-facts + contradiction-deletes. **BIG BLAST RADIUS + behavioral** — this is the genuinely net-new organ (no real summarize exists today). Land last, on its own, with a fixture-driven test (mock provider) proving merge-not-duplicate and contradiction-delete. *Flag: this introduces an LLM call into the consolidation fiber — keep it off the keeper turn hot path (it already is) and inherit the fiber's `Eio.Cancel.Cancelled` re-raise + crash isolation.*

Steps 0-6 are independently mergeable and leave a compiling, score-free system even if Step 7 is delayed.

---

## 5. RISKS / OPEN QUESTIONS — strict-reviewer flags

**R1 — count-as-score smuggling (the `>= 2` keeper rule).** The distinct-keeper count survives as a SUMMARIZE pre-filter. This is defensible *only* as a provenance fact ("≥2 keepers independently said this" → candidate group), NOT as a ranking. The moment anyone writes "promote if count ≥ N and ... " as the *decision*, a score is back. **Hard rule for Step 7**: the count selects *what the LLM looks at*; the LLM decides *what survives*. If the implementer cannot keep that boundary, drop the count entirely and let the judgment pass see all cross-keeper duplicates.

**R2 — hot-path forgetting after `score_fact` cap deletion (Step 1).** GC is default-OFF, so the cap is the only live forgetter. Step 1's structural keep-newest cap must land *with* the score deletion, or the store grows unbounded. **Open question**: is keep-newest-by-`first_seen` an acceptable hot-path bound, or must the cap also be category-aware (drop `Ephemeral`/`Unknown` before durable kinds)? I recommend category-aware structural drop order — but that ordering is itself a *typed* decision (category sum), not a score, so it stays clean.

**R3 — `tokenize`/lexical matching re-introducing a relevance score.** `lexical_relevance` is deleted. But the UPDATE "candidate-matching existing facts" lookup and any recall seed-matching will be tempted to rank by token-overlap fraction (the exact formula at `policy.ml:105`). **Hard rule**: token overlap may *retrieve candidates* (a set membership pre-filter feeding the LLM), but must NOT *order* what the keeper sees or decide what's kept. A `float matched / total` that gates anything is a score by the back door.

**R4 — `category_of_string` Unknown arm is the only string→typed boundary; do not add a second.** The SUCCESS/FAILURE arms parse through the existing single `category_of_string`. Resist adding a separate substring classifier for "did this fail" (e.g. `String.contains claim "failed"`). Valence is the LLM's typed output (`category`), parsed once. If the producer can't reliably set `Validated_approach`/`Lesson`, that's a *prompt* fix, not a string-match post-processor.

**R5 — codec migration silently dropping rows.** `fact_of_json` currently *requires* `confidence` (`types.ml:275,329`). If Step 5 is done carelessly (e.g. still requiring some now-removed field), all 6462 fleet rows fail to parse and vanish. The migration is *correct only if* a v2 fixture row round-trips. The 6462 count is fleet-only (not in this worktree), so this is the one place that cannot be fully verified locally — the fixture test is the substitute proof. **This is the single most dangerous step.**

**R6 — promotability decision for the new arms is a real choice, not a default.** I recommend `Validated_approach | Lesson -> true`, but the current whitelist is deliberately narrow (`Fact | Constraint`). Whoever lands Step 6 must decide explicitly and update the `is_promotable` contract comment (`types.ml:63-69`). Defaulting it silently would violate the no-silent-omission property the code already enforces.

**R7 — consolidation-pass non-determinism.** The consolidation pass is an LLM call; its merge/delete output is non-deterministic. It writes to durable stores and *deletes* facts (contradiction-delete). It must (a) stay off the keeper turn hot path (it is — consolidation/GC fibers), (b) inherit fault isolation (re-raise `Eio.Cancel.Cancelled`, swallow+log other failures, per `server_bootstrap_maintenance.ml:111-114,161-167`), and (c) be a permitted no-op (Claude Code §8 line 590: "if nothing changed, say so") — never forced to churn. A bad pass must degrade to "no change," not to data loss. **Open question**: does contradiction-*delete* need an append-only tombstone/audit (so a wrong delete is recoverable) rather than a hard rewrite-drop? Given the user's "remember successes well, record failures as lessons" intent, losing a fact to a hallucinated contradiction is the worst failure mode — I'd argue for a soft-supersede (mark superseded, keep one generation) over hard delete in v1.

**Files confirmed for the port** (opened: `types.ml`, `policy.ml`, `recall.ml`, `keeper_librarian_runtime.ml`): `lib/keeper/keeper_memory_os_{types,policy,consolidator,recall,gc,io}.ml`, `keeper_librarian{,_runtime}.ml`, `config/prompts/keeper.librarian.episode_extraction.md`, `lib/server/server_bootstrap_maintenance.ml`, `lib/dashboard/server_dashboard_http_keeper_api.ml`, `test/test_keeper_memory_os.ml`. I did not open `consolidator.ml`/`gc.ml`/`io.ml` myself this turn — their internals are per Map Reports 1+2, which I cross-checked against the policy/recall/runtime call sites I did open and found consistent; the implementer should confirm `consolidator.ml` line refs before deleting.
