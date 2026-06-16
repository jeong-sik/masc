---
rfc: "0243"
title: "Memory OS confidence mutability via write-side fact upsert"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
superseded_by: null
related: ["0231", "0239"]
implementation_prs: []
---

# RFC-0243 — Memory OS confidence mutability via write-side fact upsert

## §1 Problem — the score formula collapses to a constant

`Keeper_memory_os_policy.score_fact` (`lib/keeper/keeper_memory_os_policy.ml:60-66`)
multiplies five factors:

```
score = confidence
      × recency_factor(last_accessed, 7d)
      × truth_recency_factor(last_verified_at | first_seen, 30d)
      × stale_penalty(stale_factor)
      × access_factor(access_count)
```

It *looks* like it tracks staleness and re-observation. It does not. Four of
the five inputs have **no runtime producer**, so within a session the formula
collapses to `score ≈ confidence`, an LLM-generated value set once at fact
creation and never updated. This is the "accuracy inversion / gradient
collapse" flagged by the 2026-06-15 memory-systems comparison
(`reports/memory-systems-comparison-2026-06-15.html`), which scored this
subsystem last of four on Reliability (3/10).

### 1.1 Dead-field evidence (adversarially verified)

A skeptic pass searched the whole repo for any runtime writer of these fields
and failed to find one for each:

| Field | Only writer | Consequence |
|-------|-------------|-------------|
| `access_count` via `bump_access_for_turn` (`policy.ml:107`) | test-only (`test/test_keeper_memory_os.ml`) + `.mli`; **zero lib callers** | `access_factor ≡ (1+0)^0.5 = 1` |
| `stale_factor` | `keeper_librarian.ml:145` sets `0.0` at creation only | `stale_penalty ≡ 1` |
| `expected_lifetime_cycles` | `keeper_librarian.ml:147` sets `None` at creation only | `truth_lambda` always default 30d |
| `valid_until` | `keeper_librarian.ml:144` sets `None` at creation only | `fact_is_current` always true |
| `last_verified_at` | `keeper_librarian.ml:146` sets `Some now` **once** at creation | `truth_anchor` fixed at birth, never re-verified |

The update-in-place machinery already exists in `Keeper_memory_os_gc.run_gc`
(`lib/keeper/keeper_memory_os_gc.ml:76-94`: `read_facts_all → dedup → rewrite_facts_atomically`)
but it too has **zero lib callers** — it is dead. The write path is blind
append: `extract_and_append_with_provider` (`keeper_librarian_runtime.ml`)
calls `append_episode_bundle`, which fans out `List.iter append_fact`
(`keeper_memory_os_io.ml:170`). A claim re-confirmed across N turns becomes N
immortal rows, each frozen at its one-shot confidence.

### 1.2 What RFC-0239 already did (not re-litigated here)

RFC-0239 added recall-time dedup `dedup_by_claim` (`keeper_memory_os_recall.ml`)
— a read-side collapse whose own comment admits "the fact store is append-only
with no write-time dedup … ~8% exact-duplicate claims". It also added the
retention cap `cap_facts` (RFC-0239 Q4) that bounds file size by rank-and-
truncate (keeps duplicates, no merge). RFC-0239 explicitly **closed R0 ("wire
inert recall signals") as subsumed**, noting that *naive* wiring "worsens the
inversion". This RFC is the deliberate, non-naive wiring R0 deferred.

## §2 Design — one write-side upsert makes three signals live

The root fix is to make the librarian write path **upsert by claim identity**
instead of blind-append. Finding the duplicate at write time is the same moment
we update its confidence, so write-side dedup and confidence mutability are one
change, not two.

### 2.1 Claim-identity SSOT (`keeper_memory_os_types.ml`)

`normalize_claim` (lowercase + internal-whitespace-collapse + trailing-trim) is
lifted from `keeper_memory_os_recall.ml` into the shared base module. The
recall-time dedup and the write-time upsert **must** key identically, so the
fingerprint now has a single home. (`keeper_memory_os_gc.normalized_claim_key`,
trim+lower only, stays divergent but is dead; consolidating or removing it is
deferred with `run_gc` — see §4.)

### 2.2 Re-observation merge law (`keeper_memory_os_policy.ml`)

`reobserve_fact ~now ~existing ~incoming` folds a re-extracted claim into the
persisted row. **Identity and first-seen provenance are preserved** (`claim`,
`category`, `source`, `first_seen`); only the re-observation signals move:

- `confidence` → `blend_confidence` (bounded EMA, `reaffirm_weight = 0.3`):
  a convex combination, so the result stays in `[0,1]` and within the
  prior/observed band, is monotone in the observed value, and is **stable** when
  re-affirmed at the same confidence (no runaway inflation). A contradiction
  (lower re-observed confidence) pulls it down.
- `access_count += 1` → feeds `access_factor`.
- `last_accessed := now`, `last_verified_at := Some now` → feed `recency_factor`
  / `truth_recency_factor`.

Separation of concerns: `confidence` is *how sure* (quality of the latest
observation); `access_count` is *how often* (quantity). The score multiplies
them, so repeated agreement raises the score through `access_factor` even while
`confidence` holds steady.

### 2.3 Single read-modify-rewrite (`keeper_memory_os_io.ml`)

`merge_and_cap_facts ~keeper_id ~merge ~incoming ~keep ~trigger ~rank` does one
atomic cycle: `read_all_facts → merge_episode_facts → cap → rewrite_facts_atomically`.
It returns `{ merged; appended; dropped }`. `merge_episode_facts` indexes the
**first** existing row per key as the merge target (so collapsing legacy
duplicates does not spuriously inflate a re-observation count), preserves
existing file order, and appends genuinely new claims. The retention cap
(RFC-0239 Q4) is applied in the same rewrite to avoid a double read-modify-write
and a race on `facts_path`.

### 2.4 Write path (`keeper_librarian_runtime.ml`)

`extract_and_append_with_provider` now writes the episode log
(`append_episode` + `append_event`, which retain the raw claims) and then upserts
the facts via `merge_and_cap_facts ~merge:(reobserve_fact ~now)`. Because the
episode log already records the claims, a fact-merge failure (logged and
swallowed) does not lose them.

### 2.5 Cost / concurrency

The merge mutates existing rows, so the file is rewritten on every write that
carries claims (the old cap had hysteresis that skipped most rewrites). The
librarian runs at most once per turn, after a multi-second LLM call; a rewrite
of ≤ `trigger` (384) JSONL rows is off the hot path. This is not a new race
class: `cap_facts` already did read-modify-write, and a single keeper processes
turns sequentially.

## §3 Workaround screening (CLAUDE.md)

This change **removes** a workaround rather than adding one — it retires
RFC-0239's read-side `dedup_by_claim` repair to defense-in-depth by fixing the
write side.

- **Telemetry-as-fix**: no. It changes stored data (`confidence`/`access_count`/
  `last_verified_at`) and therefore the ranking, not a counter.
- **String/substring classifier**: no. It reuses the existing `normalize_claim`
  fingerprint; it adds no substring branch and introduces no behavioral coupling
  on `category` (which would re-open RFC-0239 R1).
- **N-of-M partial patch**: no. It converts the single runtime write site in one
  coherent change; no catch-all `_ ->`, no test backdoor.

It does change write semantics (append → read-modify-rewrite) and adds a scoring
rule (confidence mutates), which is why it is an RFC rather than a drive-by PR.

## §4 Out of scope / deferred

- **Dead-field removal** (`stale_factor`, `expected_lifetime_cycles`,
  `valid_until`): genuinely producer-less and not wired by this RFC. They remain
  inert `×1` multipliers. A follow-up should delete them (schema migration;
  `fact_of_json` already tolerates absent fields) per the MANIFEST "delete dead
  concepts" rule. This RFC wires `access_count`/`last_verified_at`/`confidence`
  only.
- **`run_gc` / `normalized_claim_key`**: still dead. Either wire `run_gc` to a
  periodic trigger or delete it, and consolidate its normalizer onto the §2.1
  SSOT, in the same follow-up.
- **Read-path access bump** (`bump_access_for_turn` on recall): deferred — it
  would make recall a writer (file-thrash risk). Re-observation by the librarian
  is the deterministic write-side signal this RFC uses instead.
- **Typed `category`, multi-keeper namespace, embedding search**: assessed and
  deferred/rejected in the design review; orthogonal to accuracy inversion.

## §5 Verification

- `blend_confidence` properties (bounded, convex, stable-at-equal, monotone) —
  `test/test_keeper_memory_os.ml` policy group.
- `reobserve_fact` updates signals and preserves identity — policy group.
- `merge_and_cap_facts` upserts a reworded re-observed claim into a single row
  with bumped access / blended confidence / refreshed verification, and appends
  distinct claims while the cap drops the lowest-ranked — retention group.
- The existing runtime test (`test_librarian_runtime_appends_episode_bundle`)
  exercises the new write path end-to-end and confirms episode/event/fact all
  persist.
- 32/32 `keeper_memory_os` tests pass; full `dune build` is green.
