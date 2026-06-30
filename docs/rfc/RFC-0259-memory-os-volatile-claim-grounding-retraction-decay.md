# RFC-0259: Memory OS — Volatile Claim Grounding, Retraction & Decay

**Status**: Draft
**Date**: 2026-06-19
**Supersession note (2026-06-25)**: The deterministic external-ref parser,
GitHub grounding fiber, retention/ranking effects, and recall suppression/prefix
described here are no longer active policy. Memory OS now treats PR/issue/task
mentions as model context, not as machine-enforced status facts.
**Verified against base main**: `99d3716b72` (P1–P4; the 2026-06-21 amendment re-verified §3.6/§3.7 against `c68c7d6500`)
**Builds on**: [RFC-0247](./RFC-0247-memory-os-associative-graph-forgetting-brain.md) (purge of the composite score; "a fact's value is the librarian's judgment, not a number"), [RFC-0244](./RFC-0244-memory-os-tiered-stores.md) (tiered fact stores)
**Supersedes intent of**: PR #21363 `feat(memory-os): stale decay mechanism with TTL-based GC` — **CLOSED, not merged** (`gh pr view 21363` → `state: CLOSED, mergedAt: null`). The fleet currently runs with no decay/grounding/retraction at all; this RFC re-states that need with a typed boundary instead of a flat TTL.

**Amendment (2026-06-21, base main `c68c7d6500`)**: P1–P4 landed (#21644 P1, #21665 P2, #21668 P3, #21718 P4). This revision adds **P5 — GC activation + cap TTL-awareness** (§3.6) and **P6 — producer idempotency & anchor stability** (§3.7) from the 2026-06-20 Memory OS adversarial audit (`reports/masc-memory-os-leak-stuck-audit-20260620-1614.html`, Issue #21789, defects C/E/F). The audit's resource-leak findings (cadence table, write-path fd) were fixed at the source in PR #21787 and are out of scope here. Defect D (events/episodes unbounded append) is routed to RFC-0247 (forgetting charter) as a future amendment, tracked in Issue #21789 — deferred here because amending RFC-0247's `## §1`-style body would activate a pre-existing `rfc-enforcer` gap (R5 caller-context is unsatisfiable for `docs/rfc` in CI). All file:line references in §3.6/§3.7 re-verified against `c68c7d6500`.

**Amendment (2026-06-21, P6 identity refinement)**: An adversarial review of the first P6 implementation showed the proposed identity *referent + `category`* is **unsound** — it over-merges distinct conclusions about the same referent (a status transition "PR #N is open" → "PR #N was merged" collapses to one row and the older conclusion wins, silently dropping the correction; strictly worse than P3, which kept both). §3.7's E-fix bullet is amended below: the identity must capture the **conclusion**, delivered as a **producer-emitted typed `claim_id`** with a conservative `normalize_claim` fallback, never a referent-only key. The F-fix (anchor inheritance, reconciler-only advance) is unchanged.

**Amendment (2026-06-30, base main `0d0978a05e5`): P7 — typed decay for `External_state` claims.** The 2026-06-25 supersession correctly removed prose-inferred external-ref grounding (claim prose like "PR #N" is context, not a live status assertion). But capability #3 of this RFC — *volatile classification + decay (type-level)* — was never shipped on any surviving axis: the proposed `Volatile_status` `category` arm (§3.3 option (a)) was not built, and `claim_kind = External_state` (the RFC-0285 producer-emitted origin tag, which DID survive the supersession) carries **no retention consequence**. `fact_valid_until` (`keeper_memory_os_types.ml:296-301`) places `External_state` in the same arm as `Durable_knowledge`/`Diagnostic`/`None` → `category_valid_until` → `None` for every non-`Ephemeral` category = **never hard-expires**. Worse, `reobserve_fact` (`keeper_memory_os_policy.ml:59-62`) advances `last_verified_at` for `External_state` on **mere LLM re-assertion** (re-extraction from recalled context), with no re-grounding. The same policy file (lines 51-58) already refuses this bump for `Self_observation` on the explicit grounds that *"re-extracting a recalled claim is NOT re-verification; it is the same self-narrative re-emitted from memory"* — but that guard was never extended to `External_state`, which is the identical situation. Net effect: an `External_state` claim that became false (cancelled task, resolved blocker) survives indefinitely **and** refreshes its "verified" timestamp every turn, so recall re-injects it forever — a fact "verified now" that is "false now."

Live evidence (2026-06-30): keeper `garnet` perseverated on a **cancelled** task (task-1578, `status: cancelled` in `backlog.json`) and a **resolved** blocker (`denied_missing_mapping` = 0 after restart; `masc` is mapped in `keeper_repo_mappings.toml`). Its `garnet.facts.jsonl` held 110/260 (42%) stale claims about that task/blocker (claim_kind `External_state`/`Durable_knowledge`), `last_verified_at` = current time, and these dominated its ERROR output (repeatedly probing a non-existent sandbox path `/home/keeper/playground` for a host-side mappings file). The blocker was gone; the facts were not.

**Fix (P7), consistent with the typed boundary the 2026-06-25 supersession established:** give `External_state` a finite `valid_until` keyed on the **producer-emitted `claim_kind` tag**, not on claim prose. This does NOT revive prose-inferred external_ref grounding (capability #1, which stays superseded) — it is the type-level decay (#3) on the axis that survived (`claim_kind`, RFC-0285), i.e. exactly the *"typed boundary instead of a flat TTL"* this RFC's header endorses, and the direct analogue of the existing `Self_observation` TTL.

- `keeper_memory_os_types.ml`: add `external_state_ttl_seconds` (named constant + rationale) and split `fact_valid_until` so `Some External_state -> Some (now +. external_state_ttl_seconds)`. The horizon is set at birth; `reobserve_fact` does not recompute it from `now`, so the fact expires on schedule regardless of how many times it is re-asserted. Legacy `External_state` rows already on disk with `valid_until = None` are read through an effective `first_seen + external_state_ttl_seconds` horizon, so P7 fixes the exact stale rows that motivated it instead of only new writes. Once expired, `fact_is_current = false` → recall (`facts_recency_ranked`) drops it → the loop ends.
- `keeper_memory_os_policy.ml` (companion, semantic honesty): move `Some External_state` out of the `reobserve_fact` `last_verified_at`-bump arm, mirroring `Self_observation`, so re-extraction from recalled context no longer advances the staleness timestamp (and the cap stops treating an echoed claim as "recently verified"). Re-observation may only materialize the legacy first-seen horizon for old rows; it must not extend the horizon.
- `keeper_memory_os_consolidation.ml`: consolidated `External_state` groups inherit the earliest stored/effective member horizon. Consolidation must not collapse volatile external-state rows back into `valid_until = None`.
- Explicitly out of scope (remain superseded): prose `external_ref` inference, the GitHub grounding fiber, and recall prefix/suppression. A TTL keyed on the producer-emitted tag reintroduces none of these.
- TTL length is a tuning parameter (RFC-0285 §7 frames volatility horizons in cycles): too short churns still-true context, too long lets the loop persist. Start conservative and revisit; the loop-duration bound is the safety property, not an exact value.

Tests (pure, deterministic — no harness): `fact_valid_until ~claim_kind:(Some External_state)` is finite for every category (never `None`), while `Durable_knowledge`/`Self_observation`/`Diagnostic`/`None` arms are unchanged; `fact_is_current` returns false for an `External_state` fact past its horizon; and a garnet-style regression where a stale `External_state` claim about a cancelled task is present in recall before `now` passes the horizon and absent after.

## 1. Summary

A keeper accumulates facts about **volatile external state** — "PR #X is OPEN/MERGEABLE", "PR #Y merged", "all work complete" — and persists them as **durable** facts (`category = Fact/Constraint`, `valid_until = None`). Such a fact was true when extracted and becomes false when the world moves on, but the Memory OS has **no mechanism to re-verify, retract, or decay it**. It is re-injected into recall every turn, with only a cosmetic `[stale: … verify]` annotation, until cap eviction (256/384 pressure) happens to drop it. Keepers therefore act on stale truths for many turns.

This RFC adds three coupled capabilities, each behind a clear boundary:

1. **Grounding** (deterministic) — a claim that references verifiable external state (a PR/issue id) is re-checked against the source of truth (`gh`/GitHub API) by an off-hot-path reconciler. Confirmed → `last_verified_at` advances; contradicted → the claim is retracted.
2. **Retraction** (producer + reconciler) — a removal path for a single claim. Today fact removal only happens via TTL (Ephemeral only), dedup, or cap eviction; there is no "this claim is now false, delete it."
3. **Volatile classification + decay** (type-level) — claims whose truth is time-bound (status/completion claims) carry a finite `valid_until` so they cannot outlive their verification horizon even when grounding has no external referent to check.

The boundary stays where RFC-0247 put it — **judgment = LLM, structure = deterministic** — and adds: **grounding of externally-verifiable claims = deterministic, not LLM and not never.**

## 2. Problem (first-hand evidence)

### 2.1 The lived symptom

A keeper reported (≈30 consecutive turns) that recall kept asserting its research PR was about to merge / its role was done, while the PR was in fact closed. Reproduced directly against the live store at `<base-path>/.masc/config/keepers/`:

`issue_king.facts.jsonl` held five mutually-contradictory, now-false **durable** (`category:"fact"`, no `valid_until`) claims about PR #21363:

```
"PR #21363 is OPEN, MERGEABLE, and BLOCKED by failed CI runs (…27649030331…)."
"PR #21363 is currently OPEN, MERGEABLE, and BLOCKED."
"PR #21363 is blocked because the reviewDecision is empty (no reviews yet)."
"The latest CI runs for PR #21363 are all SUCCESS."          ← contradicts row 1
"PR #21363 is open, mergeable, all CI passing, blocked because no reviews."
```

Live state: `gh pr view 21363` → **CLOSED, mergedAt=null**. Every "OPEN/MERGEABLE/BLOCKED/CI-SUCCESS" row is false, `last_verified_at` frozen at first extraction (days old), no removal path. (These five rows were purged manually as an immediate unblock; this RFC is the systemic fix so it does not recur.)

A parallel instance in `verifier.facts.jsonl`: `"All verifier work is complete: PR #21249 merged, … done."` — a durable "completion" claim. #21249 is indeed merged, but "all work complete" is a time-bound judgment persisted as a durable truth.

### 2.2 Root cause (verified in code)

| # | Gap | Evidence |
|---|---|---|
| 1 | **No retraction path** | `keeper_librarian.ml` has zero `delete`/`retract`/`supersede`/`invalidate`. The episode schema the LLM emits cannot mark a prior claim false. A contradicting later claim is *appended*, it does not remove the earlier one. |
| 2 | **No live-state grounding** | No code re-checks a "PR/issue #X is …" claim against GitHub. The system never runs the verification it tells keepers to do. |
| 3 | **`delete-on-contradiction` is comment-only** | `keeper_memory_os_types.ml` and `keeper_memory_os_gc.ml` both state "Forgetting is the librarian's delete-on-contradiction judgment"; no such code exists. |
| 4 | **Durable facts are immortal** | `category_valid_until` returns `Some` only for `Ephemeral`; `Fact`/`Constraint` → `None` → never TTL-expire. Removal is only dedup or cap eviction. `last_verified_at` is set once and never advanced for an un-re-observed claim. |
| 5 | **Recall staleness marker is cosmetic** | `keeper_memory_os_recall.staleness_marker` appends `[stale: … verify]` but still asserts the claim in the prompt; it neither suppresses nor demotes. |

PR #21363 (a flat TTL decay) tried to address #4 and was closed. This RFC narrows the mechanism (volatile-only, grounded) so it is adoptable.

## 3. Design

### 3.1 Boundary map

| Concern | Kind | Owner |
|---|---|---|
| Is a claim externally verifiable, and against what id? | structured producer output only | librarian / future typed producer |
| Re-check PR/issue #X against truth | model/live context, not automatic code inference | keeper turn context |
| Confirmed/contradicted decision from the diff | historical/superseded | no production verifier |
| Time-bound claim with no external referent | deterministic (TTL) | `category_valid_until` |
| Which claim a new observation supersedes | LLM judgment | librarian (shipped as the re-observe UPSERT, not a schema field; see §3.7) |
| Recall suppression of unverified-volatile-past-horizon | historical/superseded | no production suppression path |

Current boundary statement: **a claim that mentions PR/issue/task text is not, by itself, machine-readable external state.** Memory OS provides context; the model and live task context decide how to use it. Code only treats a fact as externally referenced when a producer supplies structured `external_ref` data explicitly.

### 3.2 Classification (P1)

Historical proposal: add a typed marker for volatility. Two candidate shapes were considered:

- **(a) New category arm** `Volatile_status` in the closed `category` sum — exhaustive `is_promotable`/`category_valid_until` force a compile-time decision (consistent with RFC-0247's "no `_` catch-all" lineage).
- **(b) Orthogonal `external_ref : { kind : Pr | Issue | Task; id : string } option` field** on `fact`, set by the producer when the claim names an id, leaving `category` for topic.

(b) was initially preferred, but the implementation path was superseded on 2026-06-25. Current Memory OS does **not** infer, persist, display, rank, or ground `external_ref` from claim prose. A claim mentioning `PR #N` keeps the category/claim_kind retention path; live PR/issue status must come from live task context or a future explicitly structured producer.

### 3.3 Reconciler (P2)

Historical proposal, now superseded: an off-hot-path fiber (mirrors the GC/consolidation fibers in `server_bootstrap_maintenance.ml`), default-OFF behind an env gate until a live dry-run validates it:

```
for each keeper, for each fact with external_ref = Some r and (now - last_verified_at) > grounding_horizon:
  match verify_external r with        (* deterministic: gh pr/issue view, cached, rate-limited *)
  | Confirmed   -> advance last_verified_at = now
  | Contradicted-> retract the fact    (* the new removal path, P3 below *)
  | Unknown     -> leave unchanged (network/transient) — never delete on uncertainty
```

This verifier design is historical. Active code now removes the pure reconciler,
GitHub verifier, env gate, and prose-derived ref producer.

### 3.4 Retraction (P3)

> **Superseded by §3.7:** the `supersedes : string list` episode field described below was never implemented; P3 shipped the in-place `merge_and_cap_facts` / `reobserve_fact` UPSERT (keyed on exact `normalize_claim`) instead. The original design is retained here for intent. P6 (§3.7) extends that shipped UPSERT.

A single-claim removal under the facts lock (P3 must use the lock that PR #21529 added to GC). Note the two removal callers key differently and both must be supported by the same removal primitive:

- **Historical reconciler path** would retract on `Contradicted`, keyed on the fact's `external_ref` identity. This path is not active production policy.
- **Librarian** gains an episode-schema `supersedes: string list` (normalized claims the new extraction invalidates), keyed on `normalize_claim`; the write path removes those rows in the same atomic rewrite as the upsert. This implements the long-promised "delete-on-contradiction" as real code (gap #3).

### 3.5 Recall suppression (P4)

Historical proposal, now superseded: a volatile claim past its `grounding_horizon` would be suppressed from the recall block, or demoted and rendered with a hard "UNVERIFIED" prefix. Current recall does not run this external-ref suppression because Memory OS no longer treats PR/issue prose as a machine status field.

### 3.6 GC activation + cap TTL-awareness (P5)

**Scope: disk-hygiene + retention-path determinism — no prompt-behavior change.** Recall already filters expired rows at read time (P4 / `fact_is_current`), so this phase does not change what a keeper sees; it stops expired rows accumulating on disk and makes the cap and the GC agree on what `valid_until` means. P5 must not be cited later as license for a read-side or symptom-suppression cap.

The original P1 attempted to close gap #4 by giving `external_ref` claims a finite `valid_until`. That policy is superseded. The remaining active GC concern is narrower: rows that already carry `valid_until` from category/claim_kind policy should be removed consistently by GC/cap paths.

Verified on `c68c7d6500`:

- The sole disk path that drops a fact on `valid_until` expiry is `run_gc` (`keeper_memory_os_gc.ml:24-28` `ttl_expired`, partitioned at `:118-120`). A fleet-wide `rg` finds no other `now > valid_until` drop in `lib/`.
- That GC fiber is **default-OFF** behind `MASC_KEEPER_MEMORY_OS_GC ~default:false` (`server_bootstrap_maintenance.ml:140-144`, "mirrors the consolidation gate").
- The hot-path cap (`cap_facts` `keeper_memory_os_io.ml:510-531`, `merge_and_cap_facts:584+`) fires only when the store exceeds `fact_store_max = 384` (`fact_recall_window 256 + 128`, `io.ml:474/484`) and then sorts by `retention_rank` (`keeper_memory_os_policy.ml:29-38`). `retention_rank` takes `~now` but uses it **only to pick a tier** (durable `1.0e15` vs non-durable `0.0`, keyed on `external_ref`/`category_valid_until` being `Some`); it never tests whether *this* fact's `valid_until` has already passed.

Net: a < 384-row store with GC off keeps expired rows on disk indefinitely (audit: `mad-improver` had 140/140 expired-`valid_until` rows, all 348 rows still present).

**Boundary.** This is a **disk leak, not a prompt leak**: recall already filters expired rows at read time (`fact_is_current`, `keeper_memory_os_recall.ml:264`, predicate `keeper_memory_os_types.ml:267-271`), so a stale row never reaches the prompt. The fix is disk hygiene plus making the two retention paths agree.

**Design — two deterministic gaps closed, not a new janitor:**

1. **Dry-run-gated GC default flip.** A fleet-wide dry-run logs what each keeper's GC would prune; after review, `MASC_KEEPER_MEMORY_OS_GC` defaults ON. Same rollout discipline as the P2 reconciler and the consolidation fiber — the env knob and dry-run already exist.
2. **Cap honors the typed `valid_until`.** The hot-path cap drops `valid_until < now` rows **before** ranking, via a pure helper (`partition_expired ~now`, reusing `gc.ml`'s `ttl_expired`) applied at the cap entry. Expiry then no longer depends solely on the 600s sweep being enabled; cap and GC enforce the *same* typed boundary.

**Anti-workaround.** "Add a TTL prune janitor" is the cap/prune-as-fix signature and is rejected. The existing bound (`fact_store_max`) is unchanged; P5 only (a) turns on the existing GC behind its existing gate and (b) removes a determinism gap where the cap and the GC disagree about what `valid_until` means. No new cap, cooldown, or symptom counter.

### 3.7 Producer idempotency & anchor stability (P6)

**Correction to §3.4.** §3.4 described a librarian episode field `supersedes : string list`. That field was never implemented (the only `supersedes` *record field* in the tree is the unrelated `operator_judgment.ml:23`; the substring also appears in some function names/comments). The dedup that P3 actually shipped is the in-place **UPSERT**: `merge_and_cap_facts ~merge:(reobserve_fact ~now)` (`keeper_librarian_runtime.ml:554-560`), keyed on **exact `normalize_claim`** (`merge_episode_facts` `keeper_memory_os_io.ml:548-574`; `normalize_claim` SSOT `keeper_memory_os_types.ml:382-398`; `reobserve_fact` `keeper_memory_os_policy.ml:56-63`). P6 extends **that** mechanism. E and F share one root: the librarian re-extracts the same self-narrative every cycle with micro-rewording, so the producer is not idempotent.

**E — semantic-dup re-mint bypasses exact dedup.** `normalize_claim` only lowercases, collapses whitespace, and trims. A reworded variant survives normalization with a *different* key, so `merge_episode_facts` takes the append branch and writes a new row (audit: one "All verification work complete: PR #21249" claim re-minted as 15–23 micro-variants).

- **Fix (producer identity, not post-hoc dedup):** give the librarian episode a **stable claim identity**, so an unchanged re-extraction UPSERTs the existing row instead of appending. This fixes *why the same claim is re-minted as a new row every cycle*.
- **The identity must capture the *conclusion*, not just the referent (2026-06-21 amendment).** The first implementation approximated identity as `external_ref` + `category` and was found unsound in adversarial review: `category` (`Fact`/`Goal`/…) does not separate two *different conclusions* about one referent — "PR #N is open" and "PR #N was merged" are both `Fact`/`Pr`/N. Keying on the referent alone collapses a status transition into one row; `reobserve_fact` then keeps the older conclusion and **silently drops the librarian's own correction**. Nothing restores it: the reconciler (§3.3) never rewrites claim text (`Stale_terminal` demotes-not-deletes, `Stale_open` only advances `last_verified_at`) and gap #3 (`supersedes`) is unimplemented. That is strictly worse than P3, which kept both rows. A referent-only key is therefore **rejected**.
- **Mechanism: a producer-emitted typed `claim_id`.** The librarian episode schema gains a `claim_id` per claim — a short stable slug for the *conclusion* (not the wording): a reworded re-statement of the same conclusion reuses the id, a changed conclusion uses a new id. The on-disk `fact` gains `claim_id : string option`, omitted-when-`None` (byte-stable for legacy rows). `claim_identity` keys on the `claim_id` when present, else falls back to `normalize_claim`. Letting the librarian assign the identity is consistent with RFC-0247's tenet that *the librarian's judgment* decides what facts exist — here the judgment "is this the same conclusion?" surfaced as a typed key, **not** a deterministic status/embedding classifier we author (which would be the string-classifier workaround a textual referent-kind discriminator slid toward).
- **Degrade is conservative — it never over-merges.** A claim with no `claim_id` (legacy row, or the model omitting it) uses the exact-text `normalize_claim` key = pre-P6 append behavior. An inconsistent id (the model emitting *different* ids for the same conclusion) at worst misses a merge and appends (the E duplicate, the status quo). The only way to over-merge is the model emitting the *same* id for *distinct* conclusions; the prompt instructs one slug per conclusion, and a wrong merge is a same-keeper judgment error. That is categorically less harmful than the referent-only key, which over-merged *by construction*.
- **Anti-workaround (the trap):** adding fuzzy / semantic / embedding dedup is a **double signature violation** (string-classifier + dedup) under the CLAUDE.md bar and is **rejected** — it suppresses the 15–23-copy symptom and trains the fleet to treat clustering as the fix. RFC-0247 §3 already rejects read-side dedup; the root is producer identity.

**F — re-mint freshness reset (anchor mutability).** The rejected implementation treated PR/issue/task prose as volatile external state, then tried to manage freshness with `external_ref`, a volatile TTL, recall demotion, and a GitHub reconciliation fiber. That path was too strong for prose: "PR #N" can be history, context, or a durable lesson, not necessarily a live status assertion. A reworded claim could therefore get a new anchor and status treatment from a string match rather than from a typed producer decision.

- **Current fix (remove the forced classifier):** Memory OS no longer infers `external_ref` from claim prose, no longer serializes it in fact/dashboard JSON, and no longer schedules GitHub grounding maintenance from that field. The claim text stays model context; live PR/issue truth belongs in live task context or a future structured producer.
- **Stable identity remains the real dedup fix:** `claim_id` still prevents same-conclusion re-mints from appending endlessly. Missing/inconsistent ids degrade to exact-text behavior instead of a code-authored referent classifier.
- **Reconcile code removed:** the pure core and GitHub verifier were both removed with the production surface. Reintroducing external grounding requires a future typed producer and a fresh RFC/update, not hidden string parsing.

## 4. Verification / harness

This section is historical. The active verification now pins the retraction instead:

- **Unit**: claim prose such as `PR #N` is not parsed into `external_ref`; legacy JSON
  with `external_ref` decodes to `None`; fact/dashboard JSON omits `external_ref`.
- **Retention/recall**: `external_ref` does not change `valid_until`, retention rank,
  re-observation, recall prefixing, or recall ordering.
- **Runtime wiring**: the GitHub grounding adapter, scheduler env vars, and reconciler
  tests are removed rather than left dormant.
- **P5**: dry-run GC log fixture (mixed `valid_until` store → asserts `ttl_expired`/`written`); pure `partition_expired ~now` / cap-TTL helper test (durable `None` never dropped; expired dropped *before* ranking; expired not retained when fresh rows exist).
- **P6**: reworded-variant test (two reworded episodes → one row once identity is stable); pure anchor test (same-identity re-observe preserves `first_seen`; reconciler-confirm advances `last_verified_at`; producer-rewording does not); TLA bug action `ReMintResetsAnchor` violates `NoUnverifiedVolatileClaimSurvivesBeyondHorizon`.

## 5. Tradeoffs & alternatives

- **External IO in the memory loop.** Grounding adds GitHub calls. Mitigated: off-hot-path, batched GraphQL, rate-limited, cached, `Unknown`-on-failure (never deletes on a flaky network). The alternative — never verifying — is the current bug.
- **Flat TTL on everything (PR #21363's approach).** Rejected: it decays durable judgment facts too, which RFC-0247 deliberately keeps. Volatility must be typed, not global.
- **LLM-only "is this still true?"** Rejected for externally-verifiable claims: the LLM sees only stale history; the truth is one deterministic API call away.
- **Do nothing / rely on cap eviction.** Status quo. A false durable fact survives until 256/384 cap pressure — observed to be ≥30 turns. Unacceptable for agents that act on memory.

## 6. Scope boundaries (what this RFC does NOT do)

- Does not re-introduce the composite importance score (RFC-0247 stays).
- Does not ground free-text judgment claims with no external referent — those keep relying on librarian judgment + (new) volatile TTL.
- Does not change the durable-fact path for non-volatile knowledge.
- Does **not** add post-hoc fuzzy/semantic/embedding dedup. Defect E is fixed at the producer's claim identity (P6), never by read-side clustering — that would be the string-classifier + dedup workaround signature.
- Does **not** bound events/episodes append (defect D). That general retention concern is routed to RFC-0247 (forgetting charter) as a future amendment (tracked in Issue #21789), to be gated by the RFC-0228 recall@depth harness.

## 7. Phasing

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | Superseded: `external_ref` classification + volatile `valid_until` | removed from active production policy |
| P2 | Superseded: reconciler fiber w/ injected `verify_external` | no production GitHub verifier/env gate |
| P3 | Superseded in part: retraction path via reconciler; producer re-observe UPSERT remains | no production external-ref retraction |
| P4 | Superseded: recall suppression/demotion of unverified-volatile | no production external-ref suppression |
| P5 | GC default flip (dry-run-gated) + hot-path cap drops `valid_until < now` before ranking (defect C) — **disk-hygiene + retention-path determinism only, no prompt-behavior change** | dry-run log reviewed; pure-helper unit + property: durable never dropped, expired ≤ horizon removed |
| P6 | producer idempotency: stable-identity upsert (E); external-ref anchor/reconciler pieces superseded | reworded→1-row test |

P1 alone closes root-cause gap #4 (immortal volatile facts) at the type level and is shippable independently. P5 is independent and shippable alone; within P6, the stable-identity work (E) precedes anchor inheritance (F).
