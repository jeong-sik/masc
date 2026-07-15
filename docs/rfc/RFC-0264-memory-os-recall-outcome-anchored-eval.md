---
rfc: 0264
title: "Memory OS recall outcome-anchored eval harness"
status: Draft
authors: [vincent, claude]
created: 2026-06-19
supersedes: []
related: [RFC-0199, RFC-0222, RFC-0247, RFC-0259, RFC-0244, RFC-0252]
implementation_prs: []
---

# RFC-0264: Memory OS recall outcome-anchored eval harness

Status: Draft · Harness-first · The bottleneck is not a missing measurement tool — it is the missing *plumbing* that connects a recall to the outcome that followed.

> This RFC was rewritten after a 4-dimension adversarial review (2026-06-19, 6 PR-blockers) refuted the first draft's three core premises. Every "already exists" claim below is now pinned to code; where the substrate is absent the RFC says so and lists it as a prerequisite, not a given.

## §1 Problem — we measure store cleanliness; we cannot measure recall effect, and we lack the wiring to start

The 2026-06-19 adversarial audit (HEAD `70166f1889`, 49 confirmed findings) reached one conclusion the existing harness cannot refute: **no measurement links memory recall to agent productivity.**

Today (`scripts/memory_os_judge_eval.py`): `noise_rate = ephemeral / (ephemeral + durable)` — store cleanliness, not "did recalled context help finish a real task". `rg 'outcome|task.*success' scripts/memory_os_judge_eval.py` → 0 hits.

But the gap is deeper than a missing metric. Three substrates the obvious design would assume **do not exist**, verified at HEAD:

1. **No outcome evaluator is wired.** The typed evidence schema is RFC-0199 `Evidence_claim.t` (`PR_merged {repo;pr_number} | CI_pass | Tests_pass | Artifact_exists | File_changed | Custom_check`). Its `.mli` states: *"this schema is currently UNWIRED … the `t list` was removed (fan-in 0: never populated, never read, no Phase B evaluator)"*. The RFC-0222 `acceptance` type (`Pr_merged`/`Command_exits_zero`/`Manual_review`) is a **proposal only** — `rg 'type acceptance' lib/` → 0 hits, RFC-0222 `implementation_prs: []`. So there is no live producer of objective outcomes to join against.
2. **The trace↔task join key exists; only the PR-outcome lookup is missing.** `execution_receipt` (`<masc_root>/keepers/<k>/execution-receipts/YYYY-MM/DD.jsonl`) already records `trace_id` + `current_task_id` + turn `outcome` every turn (verified against live receipts 2026-06-19). `costs.jsonl` lacks it (`task_id` null in 14531/14531, no `trace_id`) but that is a billing stream, irrelevant. So a trace can be joined to its task today; what is absent is the **PR/CI merge state** for that task — a forge lookup (P-b), not a producer change. (The first draft mis-stated this as "no join key", having looked only at `costs.jsonl`.)
3. **The measurement tool is not CI-safe.** `calibrate` runs unconditionally in every mode and POSTs to a live judge endpoint (`_chat → urllib.request.urlopen → /chat/completions`); it `sys.exit`s without endpoint+credentials. "Run measure/calibrate in CI, no live LLM" is false.

So "Harness First" is violated *and* the harness cannot simply be turned on — its inputs are not plumbed. This RFC builds the plumbing first, then the metric. It is the gate for all other Memory OS work (`consolidate` wiring, recall rerank, GC default-on); none of those can prove improvement until this lands.

## §2 Boundary — orthogonal axes (do not collide)

| Axis | Owner |
|------|-------|
| Typed deterministic evidence schema (PR_merged/CI_pass/…) | RFC-0199 (Phase A schema present, Phase B evaluator **not implemented**) |
| What "done" means for a checkable task (task contract) | RFC-0222 (`acceptance` **proposal, unimplemented**) |
| Recall ordering (structural, no learned number) | RFC-0247 (edge/activation organ removed by RFC-0251) |
| Volatile claim grounding / retraction / decay; `external_ref` field | RFC-0259 (Draft; `external_ref` is option (b), **unimplemented**) |
| **Whether recall changed the outcome — measurement + the plumbing for it** | **This RFC (0264)** |

0264 introduces **no behavior change to recall or write** (its injection ledger, §3.2, is append-only, never read on the hot path). It adds **no producer-side field at all**: trace linkage already exists in `execution_receipt`. 0264 is pure measurement — a read-only forge collector plus offline metrics.

## §3 Design

### §3.0 Prerequisites (P-a already exists; P-b/P-c are the real first work)

| Prereq | Gap (verified) | This RFC's resolution |
|--------|----------------|------------------------|
| **P-a trace linkage** | **already present** in `execution_receipt` (trace_id + current_task_id + outcome per turn; verified against live receipts 2026-06-19). Only `costs.jsonl` lacks it (billing, irrelevant). | No new emit needed. The forge collector (P-b) reads `execution_receipt` as the trace↔task join source. P1 was dropped to "already satisfied". |
| **P-b outcome producer** | `Evidence_claim.t` UNWIRED, fan-in 0; no Phase B evaluator; RFC-0222 acceptance unimplemented | 0264 does **not** wait for RFC-0199 Phase B. It adds an independent, read-only **forge collector**: extract PR numbers a trace touched (from `events.jsonl` claims, structured), query the forge (`gh`) for terminal merge/CI state. Converges with RFC-0199 Phase B later (same `Evidence_claim.t` shape). |
| **P-c external_ref** | RFC-0259 option (b) `external_ref : {kind;id} option`, `rg external_ref lib/` → 0 hits | Precise `recall_relevance` join needs it. Until it ships, use a coarser `normalize_claim` ⨝ PR-body/path match, explicitly labelled approximate. Hard dep for the precise metric. |

### §3.1 Ground truth = forge terminal state (objective, no judge)

The eval ground truth for a trace is the **terminal forge state** of the PR(s) it produced: `PR_merged` / `CI_pass` are objective and *monotonic* (a merged PR stays merged), so they are reproducible **given the eval timestamp is after the trace's PR reached a terminal state** (§3.3 records `eval_ts` + the observed state to keep `(trace, snapshot)` replayable). A `task_status = Done` with no typed evidence (RFC-0199 `eval_all` → `Unsatisfied "no typed claims declared"`) is **excluded** from the productivity numerator — this is the done-inflation guard, restated to match real code (there is no `Manual_review` variant in `Evidence_claim.t`).

Because the outcome is objective, **no LLM judge is in the productivity path** (only the legacy `noise_rate` judge stays LLM-based, gated by GOLD anti-rig, for store cleanliness — a separate question).

### §3.2 Recall injection ledger

Recall is injected at `keeper_run_tools_hooks.ml:347` via `render_if_enabled`, which **returns `string option` only** — the selected fact keys/episode ids are computed inside `render_context_exn` (`recall.ml:226-281`) and discarded into the rendered string. So the ledger is **not** a one-line insertion at :347; it requires extending `render_context_exn`/`render_if_enabled` to return `(block, fact_keys, episode_ids)`. With that, write an append-only ledger inside `keeper_memory_os_recall` (where `normalize_claim` keys are in scope):

```
recall_injections.jsonl  (per-keeper, sibling to facts.jsonl)
{ "trace_id", "turn", "keeper_id", "injected_fact_keys":[normalize_claim,…],
  "injected_episode_ids":[…], "n_facts_total_in_store":N, "ts":float }
```

Requirements (from review):
- **Best-effort, isolated**: the ledger write is wrapped in its own `try/with`; any FD/disk failure is swallowed (`""`/skip) and **never aborts the turn**.
- **Bounded with a concrete mechanism**: reuse `cap_facts`' read-modify-rewrite trim (N-row cap + TTL) on the ledger, not an unstated "inherits retention".
- **Deterministic**: keys are `normalize_claim` outputs (the identity SSOT), so the same trace → byte-identical ledger.
- **Append-only, never read on the hot path** → cannot change recall behavior.

### §3.3 Outcome-anchored metrics (offline, deterministic)

A new offline tool (`recall_outcome_eval.py`, sibling to `memory_os_judge_eval.py` — different ground-truth source: forge, not LLM judge) joins `recall_injections.jsonl` ⨝ trace outcome (§3.1), keyed on `trace_id` (P-a):

- `recall_relevance@merged` — of traces ending in `PR_merged`/`CI_pass`, fraction with ≥1 injected fact whose `external_ref` (P-c, RFC-0259) matches the merged deliverable. **Hard dep: RFC-0259 `external_ref`.** Interim (pre-0259): coarse `normalize_claim` ⨝ PR title/body/path, labelled approximate.
- `recall_harm@failed` — of traces ending in force-release / no-progress-loop, fraction with injected facts later proven stale/false (join with RFC-0259 retraction set).
- `recall_coverage` — injected facts / store size (audit: 94.4% invisible; `~/me/.tmp/...` audit artifact). Diagnostic rail; **gated** — an organ-flip PR that regresses coverage is flagged (so it is not a free-floating telemetry counter).

Each metric records `eval_ts` + observed forge state so `(trace, snapshot)` re-evaluates identically (forge is time-varying; only terminal states are stable).

### §3.4 CI / cron wiring (close "code exists, never runs" — honestly)

- **CI (deterministic, no network)**: pure unit tests over the offline functions only — `noise_rate` aggregation, JSON/index parsers, the ledger codec round-trip, and a **frozen GOLD fixture** (recorded judge outputs asserted against cached labels). No live judge call.
- **cron (needs network + secret)**: `calibrate` (live judge anti-rig) + `measure` (live `noise_rate`) + `recall_outcome_eval` (forge). Emits the §3.3 metrics to dashboard `behavioral_rails`.
- **Gate**: a Memory OS PR that flips an organ on (consolidate, GC, rerank) MUST report before/after of the §3.3 metrics in its body. Annotate first; ratchet to a required check after one release of data.

### §3.5 Regression ratchet

Check in an outcome-labeled trace corpus under `test/fixtures/recall_outcome/` (ledger + recorded terminal forge state + recorded judge labels). CI replays it offline and asserts metrics are byte-stable — the same byte-stability assertion methodology as RFC-0247's α=0 invariance (note: that edge organ was since removed by RFC-0251; cited for the *method*, not a live dependency). New fixtures are added when a real regression is found (loop-until-dry, not a fixed N).

## §4 Determinism boundary

- **Declarative**: which forge artifact counts as the outcome (RFC-0199 `Evidence_claim.t` shape).
- **Deterministic — fully**: the ledger, `noise_rate`, parsers, the CI ratchet (fixture corpus, no network).
- **Deterministic — conditionally (snapshot-pinned)**: the live cron metrics. Forge state is time-varying; reproducibility holds only for terminal states evaluated after the trace settled, with `eval_ts`+state recorded.
- **Non-deterministic**: only the keeper LLM doing the work, and the legacy `noise_rate` judge (store cleanliness, not the productivity path).

## §5 Anti-patterns avoided

- **Telemetry-as-fix**: the ledger is a join key feeding a ship-gate (§3.4), not "count drops and call it fixed". A PR adding the ledger without the §3.3 metrics + §3.4 gate is incomplete and should be rejected. `recall_coverage` is explicitly gated (§3.3) so it is decision-feeding, not a free counter.
- **String classifier**: outcome is typed (`Evidence_claim.t`), the precise join key is RFC-0259 typed `external_ref`; the interim `normalize_claim` ⨝ PR-text match is labelled approximate and is a *stopgap with a named replacement* (P-c), not a permanent classifier.
- **Unbounded store**: ledger reuses `cap_facts` trim (concrete mechanism, §3.2), not an unstated inherit.
- **LLM circularity**: productivity ground truth is objective forge state; no judge in that path.
- **"present" overclaim**: every dependency that is unimplemented is listed in §3.0/§2 as a prerequisite, not asserted as present.

## §6 Limitations (stated, not hidden)

1. **Observational, not causal.** `recall_relevance@merged` rising does not prove recall *caused* the merge (confounds: task difficulty, keeper, provider availability). The causal version is A/B trace replay (recall on/off on the same trace), needing deterministic replay — **explicit future RFC**.
2. **Depends on absent substrate.** The objective-outcome path needs P-a (trace linkage) and a forge collector before any number is produced; the precise relevance metric needs RFC-0259 `external_ref`. 0264's honest claim: *after the prerequisites land, we can see whether recalled context tracks real outcomes and catch regressions* — strictly more than today's zero, but not free.

## §7 Phases

| Phase | Scope | Dep |
|-------|-------|-----|
| **P0 (genuinely immediate)** | cron that runs the existing `measure` against the live store (already works — removes "never runs"); pure unit tests for `noise_rate`/parsers in CI | none |
| **P1** | trace linkage — **already satisfied**: `execution_receipt` records `trace_id` + `current_task_id` per turn (verified against live receipts 2026-06-19). No code needed. | — |
| **P2** | recall injection ledger (§3.2) — requires `render_context_exn` signature change + bounded write | trace_id (from `execution_receipt`/facts) |
| **P3** | forge outcome collector (reads `execution_receipt` for trace↔task, queries `gh` for PR/CI merge state) + `recall_outcome_eval` with `recall_harm` and *approximate* `recall_relevance` | P2 |
| **P4** | precise `recall_relevance@merged` (RFC-0259 `external_ref`) + ship-gate as required check | P3, RFC-0259 P1 merged |

Reordered from the first draft: the only "P0 = none, code exists" win is the live-measure cron. P1 (trace linkage) turned out to be **already provided by `execution_receipt`** — grounding against live data dropped a planned producer change. The real remaining sequence is ledger (P2) → forge metric (P3) → precision+gate (P4).

## §8 Done criteria

- CI runs offline unit tests (`noise_rate`, parsers, ledger codec, frozen GOLD fixture) — red on regression, no network.
- A cron runs `measure` live and surfaces `noise_rate` (removes "never runs").
- P-a: `trace_id` present on ≥99% of new cost/turn-outcome records (today: 0%).
- Ledger is deterministic (same trace → byte-identical) and bounded (`cap_facts` trim); write failure is silent/best-effort and never aborts a turn.
- `recall_harm@failed` + approximate `recall_relevance@merged` computed offline from ledger ⨝ forge, no LLM, reproducible given recorded snapshot.
- At least one organ-flip PR (e.g. GC default-on) lands with a before/after metric report.

## §9 Open questions (owner decision)

1. P-b: independent forge collector (this RFC) vs first wiring RFC-0199 Phase B (`Evidence_claim` producer)? — recommend independent collector now, converge later; do not block 0264 on RFC-0199.
2. P-a placement: trace_id on `costs.jsonl` vs a dedicated `turn_outcome.jsonl` linkage record? — recommend a dedicated record (costs is a billing stream; overloading it couples concerns).
3. P4 gate: required check vs annotation? — annotate first, ratchet to required after one release of data.
