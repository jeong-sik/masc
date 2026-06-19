# RFC-0259: Memory OS — Volatile Claim Grounding, Retraction & Decay

**Status**: Draft
**Date**: 2026-06-19
**Verified against base main**: `99d3716b72`
**Builds on**: [RFC-0247](./RFC-0247-memory-os-associative-graph-forgetting-brain.md) (purge of the composite score; "a fact's value is the librarian's judgment, not a number"), [RFC-0244](./RFC-0244-memory-os-tiered-stores.md) (tiered fact stores)
**Supersedes intent of**: PR #21363 `feat(memory-os): stale decay mechanism with TTL-based GC` — **CLOSED, not merged** (`gh pr view 21363` → `state: CLOSED, mergedAt: null`). The fleet currently runs with no decay/grounding/retraction at all; this RFC re-states that need with a typed boundary instead of a flat TTL.

## 1. Summary

A keeper accumulates facts about **volatile external state** — "PR #X is OPEN/MERGEABLE", "PR #Y merged", "all work complete" — and persists them as **durable** facts (`category = Fact/Constraint`, `valid_until = None`). Such a fact was true when extracted and becomes false when the world moves on, but the Memory OS has **no mechanism to re-verify, retract, or decay it**. It is re-injected into recall every turn, with only a cosmetic `[stale: … verify]` annotation, until cap eviction (256/384 pressure) happens to drop it. Keepers therefore act on stale truths for many turns.

This RFC adds three coupled capabilities, each behind a clear boundary:

1. **Grounding** (deterministic) — a claim that references verifiable external state (a PR/issue id) is re-checked against the source of truth (`gh`/GitHub API) by an off-hot-path reconciler. Confirmed → `last_verified_at` advances; contradicted → the claim is retracted.
2. **Retraction** (producer + reconciler) — a removal path for a single claim. Today fact removal only happens via TTL (Ephemeral only), dedup, or cap eviction; there is no "this claim is now false, delete it."
3. **Volatile classification + decay** (type-level) — claims whose truth is time-bound (status/completion claims) carry a finite `valid_until` so they cannot outlive their verification horizon even when grounding has no external referent to check.

The boundary stays where RFC-0247 put it — **judgment = LLM, structure = deterministic** — and adds: **grounding of externally-verifiable claims = deterministic, not LLM and not never.**

## 2. Problem (first-hand evidence)

### 2.1 The lived symptom

A keeper reported (≈30 consecutive turns) that recall kept asserting its research PR was about to merge / its role was done, while the PR was in fact closed. Reproduced directly against the live store at `~/me/.masc/config/keepers/`:

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
| Which claim a new observation supersedes | LLM judgment | librarian (new schema field) |
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
  | Contradicted-> retract the fact    (* the new removal path, P? below *)
  | Unknown     -> leave unchanged (network/transient) — never delete on uncertainty
```

`verify_external` is the only external-IO surface and is injected (testable with a fake, like `Keeper_librarian_runtime`'s `complete_fn`). It batches and rate-limits GitHub calls (1 GraphQL query can cover many PRs — see `workflow-pr.md` GraphQL-first).

### 3.4 Retraction (P3)

A single-claim removal under the facts lock (RFC-0259 must use the lock that PR #21529 added to GC), keyed on `normalize_claim`:

- Reconciler retracts on `Contradicted`.
- Librarian gains an episode-schema `supersedes: string list` (normalized claims the new extraction invalidates); the write path removes those rows in the same atomic rewrite as the upsert. This implements the long-promised "delete-on-contradiction" as real code (gap #3).

### 3.5 Recall suppression (P4)

A volatile claim that is past its `grounding_horizon` and unconfirmed is **suppressed** from the recall block (not merely annotated), or at minimum demoted below durable claims and rendered with a hard "UNVERIFIED — do not act without re-checking" prefix. This closes gap #5: the prompt stops asserting stale volatile truths.

## 4. Verification / harness

Per the project's "good agents come from good harnesses" tenet:

- **Unit**: classifier (id extraction), `category_valid_until` for volatile, retraction-by-claim under the lock, recall suppression past horizon. Fake `verify_external` drives Confirmed/Contradicted/Unknown.
- **Property**: a false volatile claim is removed within K reconciler cycles; a still-true claim is preserved; `Unknown` never deletes; no durable judgment claim is ever dropped by this machinery.
- **TLA+ (bug model)**: model `StaleVolatileClaim` + invariant `NoUnverifiedVolatileClaimSurvivesBeyondHorizon`; clean spec satisfies it, a `NeverReconcile` bug action violates it (mutation-testing pattern already used for `KeeperOASAdvanced.tla`).
- **Live dry-run**: reconciler in dry-run logs what it *would* retract across the fleet before the gate is enabled (same rollout discipline as GC/consolidation).

## 5. Tradeoffs & alternatives

- **External IO in the memory loop.** Grounding adds GitHub calls. Mitigated: off-hot-path, batched GraphQL, rate-limited, cached, `Unknown`-on-failure (never deletes on a flaky network). The alternative — never verifying — is the current bug.
- **Flat TTL on everything (PR #21363's approach).** Rejected: it decays durable judgment facts too, which RFC-0247 deliberately keeps. Volatility must be typed, not global.
- **LLM-only "is this still true?"** Rejected for externally-verifiable claims: the LLM sees only stale history; the truth is one deterministic API call away.
- **Do nothing / rely on cap eviction.** Status quo. A false durable fact survives until 256/384 cap pressure — observed to be ≥30 turns. Unacceptable for agents that act on memory.

## 6. Scope boundaries (what this RFC does NOT do)

- Does not re-introduce the composite importance score (RFC-0247 stays).
- Does not ground free-text judgment claims with no external referent — those keep relying on librarian judgment + (new) volatile TTL.
- Does not change the durable-fact path for non-volatile knowledge.

## 7. Phasing

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | `external_ref` classification + volatile `valid_until` (decay even without reconciler) | typed, compile-time exhaustive |
| P2 | reconciler fiber w/ injected `verify_external`, default-OFF + dry-run | live dry-run log reviewed |
| P3 | retraction path (reconciler + librarian `supersedes`) under the facts lock | property + TLA tests green |
| P4 | recall suppression/demotion of unverified-volatile | recall tests pin suppression |

P1 alone closes root-cause gap #4 (immortal volatile facts) at the type level and is shippable independently.
