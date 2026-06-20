# RFC-0259: Memory OS — Volatile Claim Grounding, Retraction & Decay

**Status**: Draft
**Date**: 2026-06-19
**Verified against base main**: `99d3716b72` (P1–P4; the 2026-06-21 amendment re-verified §3.6/§3.7 against `c68c7d6500`)
**Builds on**: [RFC-0247](./RFC-0247-memory-os-associative-graph-forgetting-brain.md) (purge of the composite score; "a fact's value is the librarian's judgment, not a number"), [RFC-0244](./RFC-0244-memory-os-tiered-stores.md) (tiered fact stores)
**Supersedes intent of**: PR #21363 `feat(memory-os): stale decay mechanism with TTL-based GC` — **CLOSED, not merged** (`gh pr view 21363` → `state: CLOSED, mergedAt: null`). The fleet currently runs with no decay/grounding/retraction at all; this RFC re-states that need with a typed boundary instead of a flat TTL.

**Amendment (2026-06-21, base main `c68c7d6500`)**: P1–P4 landed (#21644 P1, #21665 P2, #21668 P3, #21718 P4). This revision adds **P5 — GC activation + cap TTL-awareness** (§3.6) and **P6 — producer idempotency & anchor stability** (§3.7) from the 2026-06-20 Memory OS adversarial audit (`reports/masc-memory-os-leak-stuck-audit-20260620-1614.html`, Issue #21789, defects C/E/F). The audit's resource-leak findings (cadence table, write-path fd) were fixed at the source in PR #21787 and are out of scope here. Defect D (events/episodes unbounded append) is routed to RFC-0247 (forgetting charter) as a future amendment, tracked in Issue #21789 — deferred here because amending RFC-0247's `## §1`-style body would activate a pre-existing `rfc-enforcer` gap (R5 caller-context is unsatisfiable for `docs/rfc` in CI). All file:line references in §3.6/§3.7 re-verified against `c68c7d6500`.

**Amendment (2026-06-21, P6 identity refinement)**: An adversarial review of the first P6 implementation showed the proposed identity *referent + `category`* is **unsound** — it over-merges distinct conclusions about the same referent (a status transition "PR #N is open" → "PR #N was merged" collapses to one row and the older conclusion wins, silently dropping the correction; strictly worse than P3, which kept both). §3.7's E-fix bullet is amended below: the identity must capture the **conclusion**, delivered as a **producer-emitted typed `claim_id`** with a conservative `normalize_claim` fallback, never a referent-only key. The F-fix (anchor inheritance, reconciler-only advance) is unchanged.

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
| Is a claim externally verifiable, and against what id? | deterministic (parse) | classifier at producer boundary |
| Re-check PR/issue #X against truth | **external** (`gh`/GitHub API) | reconciler fiber |
| Confirmed/contradicted decision from the diff | deterministic | reconciler |
| Time-bound claim with no external referent | deterministic (TTL) | `category_valid_until` |
| Which claim a new observation supersedes | LLM judgment | librarian (shipped as the re-observe UPSERT, not a schema field; see §3.7) |
| Recall suppression of unverified-volatile-past-horizon | deterministic | recall |

The new boundary statement: **a claim that names verifiable external state must be grounded deterministically — the system can and must run the check itself.** Leaving it to the LLM (which only sees stale history) or to never-verify is what produced the bug.

### 3.2 Classification (P1)

Add a typed marker for volatility. Two candidate shapes (decision deferred to review):

- **(a) New category arm** `Volatile_status` in the closed `category` sum — exhaustive `is_promotable`/`category_valid_until` force a compile-time decision (consistent with RFC-0247's "no `_` catch-all" lineage).
- **(b) Orthogonal `external_ref : { kind : Pr | Issue | Task; id : string } option` field** on `fact`, set by the producer when the claim names an id, leaving `category` for topic.

(b) is preferred: volatility and topic are orthogonal (a `Constraint` can reference a PR). `external_ref` is parsed once at the producer boundary (parse-don't-validate), `None` when no id is named.

A claim with `external_ref = Some _` is **never durable**: it gets a finite `valid_until` (decay horizon) so #4 is closed even before the reconciler lands.

### 3.3 Reconciler (P2)

An off-hot-path fiber (mirrors the GC/consolidation fibers in `server_bootstrap_maintenance.ml`), default-OFF behind an env gate until a live dry-run validates it:

```
for each keeper, for each fact with external_ref = Some r and (now - last_verified_at) > grounding_horizon:
  match verify_external r with        (* deterministic: gh pr/issue view, cached, rate-limited *)
  | Confirmed   -> advance last_verified_at = now
  | Contradicted-> retract the fact    (* the new removal path, P3 below *)
  | Unknown     -> leave unchanged (network/transient) — never delete on uncertainty
```

`verify_external` is the only external-IO surface and is injected (testable with a fake, like `Keeper_librarian_runtime`'s `complete_fn`). It batches and rate-limits GitHub calls (1 GraphQL query can cover many PRs — see `workflow-pr.md` GraphQL-first).

### 3.4 Retraction (P3)

> **Superseded by §3.7:** the `supersedes : string list` episode field described below was never implemented; P3 shipped the in-place `merge_and_cap_facts` / `reobserve_fact` UPSERT (keyed on exact `normalize_claim`) instead. The original design is retained here for intent. P6 (§3.7) extends that shipped UPSERT.

A single-claim removal under the facts lock (P3 must use the lock that PR #21529 added to GC). Note the two removal callers key differently and both must be supported by the same removal primitive:

- **Reconciler** retracts on `Contradicted`, keyed on the fact's `external_ref` identity (it already holds the specific fact it re-checked).
- **Librarian** gains an episode-schema `supersedes: string list` (normalized claims the new extraction invalidates), keyed on `normalize_claim`; the write path removes those rows in the same atomic rewrite as the upsert. This implements the long-promised "delete-on-contradiction" as real code (gap #3).

### 3.5 Recall suppression (P4)

A volatile claim that is past its `grounding_horizon` and unconfirmed is **suppressed** from the recall block (not merely annotated), or at minimum demoted below durable claims and rendered with a hard "UNVERIFIED — do not act without re-checking" prefix. This closes gap #5: the prompt stops asserting stale volatile truths.

### 3.6 GC activation + cap TTL-awareness (P5)

**Scope: disk-hygiene + retention-path determinism — no prompt-behavior change.** Recall already filters expired rows at read time (P4 / `fact_is_current`), so this phase does not change what a keeper sees; it stops expired rows accumulating on disk and makes the cap and the GC agree on what `valid_until` means. P5 must not be cited later as license for a read-side or symptom-suppression cap.

P1 closed gap #4 at the type level — an `external_ref` claim now carries a finite `valid_until`. But **expiry only takes effect on disk through one path that is off by default**, and the always-on hot-path cap ignores `valid_until` entirely. So in a store below the cap threshold, an expired volatile row persists on disk indefinitely.

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
- **Degrade is conservative — it never over-merges.** A claim with no `claim_id` (legacy row, or the model omitting it) uses the exact-text `normalize_claim` key = pre-P6 append behavior. An inconsistent id (the model emitting *different* ids for the same conclusion) at worst misses a merge and appends (the E duplicate, the status quo). The only way to over-merge is the model emitting the *same* id for *distinct* conclusions; the prompt instructs one slug per conclusion, and a wrong merge is a same-keeper judgment error the reconciler still grounds — categorically less harmful than the referent-only key, which over-merged *by construction*.
- **Anti-workaround (the trap):** adding fuzzy / semantic / embedding dedup is a **double signature violation** (string-classifier + dedup) under the CLAUDE.md bar and is **rejected** — it suppresses the 15–23-copy symptom and trains the fleet to treat clustering as the fix. RFC-0247 §3 already rejects read-side dedup; the root is producer identity.

**F — re-mint freshness reset (anchor mutability).** When E's exact-key miss appends, the new row lands with `first_seen = now` (every producer stamps it: `keeper_librarian.ml:231`, `keeper_librarian_runtime.ml:435`) and `fact_valid_until` recomputes the 24 h volatile TTL from write-time `now` (`keeper_memory_os_types.ml:235-239`, `volatile_external_ttl_seconds = 86_400` at `:228`). `is_unverified_volatile` anchors on `last_verified_at` else `first_seen` (`keeper_memory_os_recall.ml:109-118`), so a reworded stale status claim re-enters with both the 24 h TTL **and** the 12 h grounding horizon (`default_grounding_horizon_seconds = ttl / 2 = 43_200`, `keeper_memory_os_reconcile.ml:38`) reset — no `UNVERIFIED` prefix (audit: `sangsu` #21363, 3/5 rows < 12 h).

- **Fix (anchor immutability):** on re-observe of a stable-identity claim, **inherit** the prior row's `first_seen` (and `last_verified_at`) rather than stamping fresh — decay anchors to *first* observation, not latest mint. Depends on E's identity work.
- **This amends the shipped P3, it is not additive.** The merged `reobserve_fact` (`keeper_memory_os_policy.ml:56-63`) currently does the opposite for the `external_ref` branch: on *every* producer re-observe it sets `valid_until = Some (now +. volatile_external_ttl_seconds)` and advances `last_verified_at = now`, with the comment asserting "re-observing IS re-verification." P6/F **reverses that rule for volatile claims**: the volatile-TTL / `last_verified_at` refresh moves off the producer merge path, and a stable-identity re-observe inherits the prior row's `first_seen`, `valid_until`, and `last_verified_at`. The producer no longer counts as re-verification.
- **Edge that must be distinguished:** a legitimate reconciler re-verification (`Stale_open` verdict, `keeper_memory_os_reconcile.ml:128`) advances `last_verified_at` and *should* reset the horizon — the claim was actually re-checked against GitHub. A producer rewording must not. The rule: **only the reconciler (external re-verification) advances the anchor; producer re-extraction inherits it.** Conflating the two re-introduces F (and is precisely the live `reobserve_fact` rule this phase replaces).

## 4. Verification / harness

Per the project's "good agents come from good harnesses" tenet:

- **Unit**: classifier (id extraction), `category_valid_until` for volatile, retraction-by-claim under the lock, recall suppression past horizon. Fake `verify_external` drives Confirmed/Contradicted/Unknown.
- **Property**: a false volatile claim is removed within K reconciler cycles; a still-true claim is preserved; `Unknown` never deletes; no durable judgment claim is ever dropped by this machinery.
- **TLA+ (bug model)**: model `StaleVolatileClaim` + invariant `NoUnverifiedVolatileClaimSurvivesBeyondHorizon`; clean spec satisfies it, a `NeverReconcile` bug action violates it (mutation-testing pattern already used for `KeeperOASAdvanced.tla`).
- **Live dry-run**: reconciler in dry-run logs what it *would* retract across the fleet before the gate is enabled (same rollout discipline as GC/consolidation).
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
| P1 | `external_ref` classification + volatile `valid_until` (decay even without reconciler) | typed, compile-time exhaustive |
| P2 | reconciler fiber w/ injected `verify_external`, default-OFF + dry-run | live dry-run log reviewed |
| P3 | retraction path (reconciler + librarian re-observe upsert — shipped as the `merge_and_cap_facts`/`reobserve_fact` UPSERT, not the `supersedes` field this RFC originally described; see §3.7) under the facts lock | property + TLA tests green |
| P4 | recall suppression/demotion of unverified-volatile | recall tests pin suppression |
| P5 | GC default flip (dry-run-gated) + hot-path cap drops `valid_until < now` before ranking (defect C) — **disk-hygiene + retention-path determinism only, no prompt-behavior change** | dry-run log reviewed; pure-helper unit + property: durable never dropped, expired ≤ horizon removed |
| P6 | producer idempotency: stable-identity upsert (E) + anchor inheritance on re-mint, reconciler-only horizon advance (F) | reworded→1-row test; `first_seen`-preservation unit; TLA `ReMintResetsAnchor` violates invariant |

P1 alone closes root-cause gap #4 (immortal volatile facts) at the type level and is shippable independently. P5 is independent and shippable alone; within P6, the stable-identity work (E) precedes anchor inheritance (F).
