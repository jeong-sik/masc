---
rfc: "0222"
title: "Typed acceptance criterion + harness-driven completion for checkable tasks"
status: Draft
created: 2026-06-09
updated: 2026-06-09
author: vincent
supersedes: []
superseded_by: null
related: ["0220", "0221"]
implementation_prs: []
---

# RFC-0222: Typed acceptance criterion + harness-driven completion for checkable tasks

Status: Draft · Producer-side completion convergence · Parse-don't-validate on "what is done"
Drafted by: Claude Opus 4.8 (autonomous diagnosis session 2026-06-09), pending owner review.
Diagnosis source: live-log trace `~/me/.masc/logs/system_log_2026-06-09.jsonl` (workflow w3vzy2yvq, 3-agent: log / prompt / gate) + own code reads.

> Anchors marked **(verified)** were read against the working tree on 2026-06-09 while writing. Anchors marked **(trace)** come from the diagnosis subagent and must be re-verified before implementation.

---

## §1 Problem — keepers claim tasks but never attempt completion

A keeper claims a task, runs exploration turns, and is force-released without ever calling a completion transition. The task re-enters the backlog and the cycle repeats. The highest-`cycle_count` stuck tasks demonstrate it:

| task | cycle_count | classification (trace) | completion calls observed |
|------|-------------|------------------------|---------------------------|
| task-676 (diagnose+fix WebSocket) | 50 | never_attempt / still_running | 0 |
| task-670 (sync .mli with .ml) | 33 | still_running | 0 |
| task-681 (create voice_config.json) | 12 | never_attempt | 0 |

Verdict: **never_attempt dominant (2/3, 1 still_running, 0 attempt_rejected)**. The bottleneck is not an evidence gate rejecting completion attempts — keepers do not reach a completion transition at all.

### 1.1 Completion is an LLM-discretionary action with no deterministic backstop

A task reaches `Done` only when the working keeper *chooses* to emit `keeper_task_done` (→ `Done_action`) or `masc_transition(submit_for_verification)`. The two completion transitions are gated, but both still require the LLM to *initiate* them: `Done_action` runs an LLM completion review (`tool_task.ml:251-264` **(verified)**) and `Submit_for_verification` runs the CDAL substring evidence floor, applied only for that action (`tool_task.ml:288-298` **(verified)**). There is no mechanism that observes "this task's deliverable is objectively satisfied" and advances it. When the LLM does not emit the call — because it was not instructed (see §1.2), because it cannot tell the deliverable is already satisfied, or because the work is genuinely subjective and it never converges — nothing completes the task. RFC-0220 §3.3 then keeps the keeper alive (path-1 liveness) and the oscillation cleanup re-circulates the task, but neither produces completion.

### 1.2 The proximate instruction defect (fixed separately, PR #20653)

The autonomous keeper turn builds its system prompt via `Keeper_unified_prompt.build_prompt` (`keeper_unified_prompt.ml:443`, assembled at `keeper_unified_prompt.ml:573` **(verified)**) = `keeper.unified.system.md` + turn_intent, and discards the `~base_system_prompt` parameter that carries `core_behavior.md` / `capabilities.md`:

```ocaml
(* keeper_unified_turn.ml:278 (verified) — the autonomous turn callback
   binds the base prompt to _ and returns only the unified system_prompt. *)
let build_turn_prompt ~base_system_prompt:_ ~messages:_ : Keeper_agent_run.turn_prompt =
  { system_prompt; dynamic_context = "" }
(* system_prompt = unified.system.md + turn_intent block ONLY;
   core_behavior.md / capabilities.md (the completion contract) are not in it. *)
```
 The only "you MUST close a claimed task; call `keeper_task_done` with evidence" instruction lives in `core_behavior.md:10` **(verified)**, assembled only on the reactive path. So autonomous turns were never told to complete tasks. `keeper.unified.system.md:25` **(verified)** said only "mark done" — no tool, no evidence, no close directive.

PR #20653 (`fix(keeper): restore task-completion contract to autonomous turn prompt`) restores that contract to the autonomous prompt. **That is the proximate fix and it is prose-level: completion still depends on the LLM emitting the call.** This RFC addresses the structural layer the owner asked for — completion that does not depend on the LLM remembering.

### 1.3 Why prose alone is insufficient

Restoring the instruction (PR #20653) raises the probability a keeper completes, but it does not *guarantee* convergence:

- For a **stale "create X" task whose X already exists** (task-681: `.masc/voice_config.json` present since Jun 5), the LLM must (a) recognize the artifact exists, (b) decide that satisfies the task, (c) emit `keeper_task_done` with evidence. Each step is a discretionary judgment that empirically does not happen (0 completion calls across 12 cycles).
- For a **checkable mechanical task** (task-685 "add `Runtime.all_ids`", task-670 "sync .mli with .ml"), whether the deliverable exists is a deterministic fact the harness could check — but today only the LLM's judgment gates completion.

Where "done" is a machine-checkable predicate, leaving the decision to LLM discretion is the defect. That is the Parse-don't-validate lever this RFC pulls.

---

## §2 Scope boundary vs RFC-0220 / RFC-0221 (no split-brain)

These three RFCs touch the same lifecycle but own **orthogonal axes**. Stating the boundary explicitly so the type changes do not collide:

| Concern | Owner |
|---------|-------|
| Verification-state atomicity (the `Todo+Pending` illegal pair; dual-store write) | RFC-0221 (Implemented), RFC-0220 §3.1/§3.6 |
| Scheduling decouple + keeper liveness (empty/blocked pool → autonomous turn, never idle) | RFC-0220 §3.3/§3.4 |
| Guaranteed *verifier-keeper* satisfier for `AwaitingVerification` obligations | RFC-0220 §3.5 |
| **Producer-side completion convergence — how a task reaches a completion transition at all** | **This RFC (0222)** |

RFC-0220/0221 assume the keeper *produces* a submission and fix what happens to the verification state afterward. 0222 addresses the step before: making a task's completion **observable to the harness** for the checkable subset, so completion does not depend on the producer LLM emitting the call.

### 2.1 Invariants inherited from RFC-0220 (binding constraints on this design)

- **I1 — a keeper must never permanently stop.** 0222 introduces no new idle path. Evaluation is a non-blocking turn-boundary check.
- **I2 — no heuristic per-turn / wall-clock deadline as control flow.** This **rules out** a "claimed for N cycles → escalate/blocked" mechanism (an earlier draft idea; dropped). 0222 adds zero timers. The only completion driver is predicate satisfaction.
- **`task_status` is the single authority** (RFC-0221). Harness-driven completion transitions `task_status` through the existing transition path; it introduces no side store.

### 2.2 Synergy with RFC-0220 §3.5 (guaranteed satisfier)

0220 §3.5 guarantees a *verifier-keeper* satisfier for every `AwaitingVerification` obligation (subjective tasks). 0222 provides a **deterministic satisfier** for the checkable subset: the harness predicate evaluation *is* the verification. The two compose — subjective tasks → verifier keeper (0220); checkable tasks → harness predicate (0222) — and the checkable lane *reduces* the verifier-pool load 0220 must guarantee.

---

## §3 Design — typed acceptance criterion

### 3.1 Acceptance as a declared, closed sum

Add an acceptance criterion to the task contract, **declared at task creation**, as a closed sum:

```ocaml
type acceptance =
  | Artifact_exists of { path : string }            (* file/dir present in the task's repo scope *)
  | Command_exits_zero of { argv : string list; cwd : string }  (* build/test passes *)
  | Symbol_present of { file : string; symbol : string }        (* code symbol defined *)
  | Pr_merged of { number : int }                   (* forge PR merged *)
  | Manual_review                                   (* subjective — RFC-0220 verifier path, unchanged *)
```

- **Declared, never inferred.** `masc_add_task` / `masc_batch_add_tasks` gain an optional typed `acceptance` field. The criterion is supplied by the task author. It is **never derived from the task title** — title-string inference (`title contains "create" → Artifact_exists`) is the string-classifier anti-pattern (CLAUDE.md workaround signature #2) and is explicitly forbidden.
- **Default is `Manual_review`.** A task created without an acceptance criterion (every existing task) is `Manual_review` = today's behavior. No regression, additive only.
- **Closed sum, extensible by RFC.** New predicate kinds are added as variants; the compiler enumerates every evaluation site (no catch-all).

### 3.2 Deterministic turn-boundary evaluation

After a keeper turn on a claimed task, the harness evaluates the task's acceptance predicate. This is a pure, non-blocking, deterministic check (no LLM, no timer):

- `Artifact_exists` → resolve the path in the keeper's repo scope; satisfied iff present.
- `Command_exits_zero` → run the typed argv in the scoped cwd through the existing Shell-IR/policy path; satisfied iff exit 0.
- `Symbol_present` → grep/parse the file for the symbol.
- `Pr_merged` → query the forge for merge state.
- `Manual_review` → never auto-satisfied; falls through to the existing path.

The evaluation result is a **measurement**, recorded verbatim as the completion evidence (e.g. `Artifact_exists: .masc/voice_config.json present (sha <…>)`, `Command_exits_zero: dune build exit 0`).

### 3.3 Completion path: harness-as-satisfier for checkable, verifier for subjective

When a non-`Manual_review` predicate is satisfied, the harness drives the completion transition with the measured evidence:

- For a checkable predicate, the **deterministic evaluation is the verification** — a re-runnable measurement is stronger evidence than an LLM verifier's judgment, and a second agent re-judging adds no information (it would re-run the same check). So the harness is the satisfier: `task_status → Done` with the measured evidence. This bypasses the cross-agent verifier *for checkable tasks only*, justified by the determinism of the predicate. **(Open question — §7.1: do we still route checkable completions through a one-shot verifier re-run for defense-in-depth? Owner decision.)**
- For `Manual_review`, nothing changes: the keeper submits (LLM-driven, now instructed by PR #20653), and RFC-0220 §3.5's verifier-keeper satisfies the obligation.

This draws the manifesto boundary precisely: **declarative** (the acceptance criterion) / **deterministic** (harness evaluation + completion for checkable) / **non-deterministic** (the LLM does the work that makes the predicate true; and judges subjective `Manual_review` tasks).

### 3.4 What this is NOT — the rejected auto-fill workaround

A previously-floated "fix" was: when the keeper does not supply evidence, auto-inject `completion_notes = "auto-verified: deliverable exists"`. That is rejected (CLAUDE.md "Repair / Sanitize" + "Telemetry-as-fix" signatures): it fabricates a string that asserts done-ness **without proof**, and does not fix why the keeper did not converge.

Typed acceptance is the opposite: the contract **declares** the done-condition up front, and the harness **measures** it. The evidence is a measurement that can be re-run, not a fabricated claim. The distinction is *provability* — auto-fill asserts, 0222 measures.

---

## §4 Why this is not a workaround (CLAUDE.md gate self-check)

| Signature | Applies? | Why |
|-----------|----------|-----|
| Telemetry-as-fix | No | No counter introduced as a fix; completion actually advances via a measured predicate. |
| String/substring classifier | No | Acceptance is a **typed closed sum declared at creation**, never inferred from title strings. Title-inference is explicitly forbidden (§3.1). |
| N-of-M patch | No | Single typed field + one evaluator with an exhaustive match over the closed sum; the compiler enumerates every site. |
| Cap / cooldown / dedup / repair | No | No timer, cap, or cycle threshold (I2). The earlier "N-cycle escalation" idea was dropped precisely to avoid this. Not repair-on-read: the criterion is checked to *drive completion*, not to sanitize a drifted store. |
| catch-all `_ ->` added | No | `acceptance` is a closed sum; evaluation stays exhaustive. |
| test backdoor | No | None. |
| same fix N sites | No | One declared field, one evaluator. |

This RFC removes LLM-discretion from completion for the checkable subset by making "done" a parseable value the harness evaluates — Parse-don't-validate, not a symptom patch.

---

## §5 Relationship to PR #20653 (Defect A)

PR #20653 restores the completion *instruction* to the autonomous prompt — necessary for `Manual_review` (subjective) tasks, which remain LLM-driven. 0222 makes completion *harness-driven* for the checkable subset, so those tasks no longer depend on the LLM emitting the call. The two are complementary: A covers the subjective path's instruction gap; 0222 removes the discretion entirely for checkable tasks. 0222 does **not** supersede A — subjective tasks still need the instruction A restores.

---

## §6 Honest limits (tradeoffs)

1. **Checkable-only.** The worst churner (task-676, cyc50, "diagnose+fix WebSocket disconnection") is subjective → `Manual_review` → still LLM-driven. 0222 does **not** solve subjective non-convergence. For those, the levers are PR #20653 (instruction) + RFC-0220 (liveness/satisfier) + harness/eval quality — a separate problem.
2. **Adoption-bottlenecked.** Someone (often an LLM via `masc_add_task`) must declare the right predicate. A mis-declared or undeclared criterion → `Manual_review` = today's behavior. So 0222 is an additive lane, not a universal fix. Mitigation: creation-time *suggestion* of a predicate for obvious shapes (suggestion surfaced to the author, never auto-applied — auto-apply would be the §3.1 string-classifier).
3. **Verifier bypass for checkable tasks** (§3.3) removes the cross-agent check for that subset. Justified by predicate determinism, but a reviewer may want defense-in-depth (§7.1).
4. **`Command_exits_zero` runs work at the turn boundary** — must reuse the existing Shell-IR/policy + sandbox path (no new execution surface), and must be cheap/idempotent or it becomes a per-turn cost. Restrict to declared, scoped commands.

---

## §7 Open questions (owner decisions)

1. **Defense-in-depth for checkable completion (§3.3):** harness-as-satisfier straight to `Done`, or harness pre-verifies then routes through a one-shot verifier re-run? The former is simpler and the predicate is authoritative; the latter keeps a uniform cross-agent audit at the cost of a round-trip that adds no information for a deterministic predicate.
2. **Evaluation site:** keeper turn loop (after the keeper's turn on its claimed task) vs scheduler-side sweep over claimed tasks. The turn-loop site keeps it keeper-scoped and avoids a global sweep; the scheduler site catches stale-but-already-satisfied tasks no keeper currently holds (task-681). Possibly both: turn-loop for the active claim, plus a scheduler check at claim time so a stale satisfied task completes immediately on claim instead of after an exploration turn.
3. **Predicate set v1:** start with `Artifact_exists` + `Command_exits_zero` + `Manual_review` only (covers create-file + build/test/sync), defer `Symbol_present` / `Pr_merged` to a follow-up once the evaluation harness is proven.

---

## §8 Test plan

- **Unit** — one test per `acceptance` variant evaluator: satisfied / unsatisfied / evaluation-error (e.g. `Command_exits_zero` when the command itself errors ≠ predicate satisfied).
- **Property / regression** — an undeclared task resolves to `Manual_review` and follows the unchanged path (no auto-completion); proves additivity / no regression on the 296 existing done + all current todos.
- **Integration** — a checkable task with `Artifact_exists` and the artifact present completes to `Done` with measured evidence and **without** a verifier round-trip; with the artifact absent it stays `InProgress` and the keeper keeps working (no false completion).
- **Mutation / clean-buggy** (CLAUDE.md §TLA+ bug-model): model `HarnessCompletesManualReviewWithoutVerifier` as a `BugAction`; invariant `ManualReviewAlwaysCrossAgentVerified` must be violated under `NextBuggy` and hold under clean `Next`. Also a no-fabrication invariant: `Done ⟹ (predicate measured satisfied ∨ cross-agent verified)` — there is no path to `Done` from an unsatisfied predicate.

---

## §9 Rollout

Additive. Default `Manual_review` everywhere → zero behavior change until tasks declare criteria. Ship the type + evaluator + the `masc_add_task` field first (inert until used), then opt in per task, then measure: completion rate and cycle_count on checkable tasks before/after. The metric that proves 0222 worked is **checkable-task cycle_count → ~1** (claim → satisfied predicate → Done in one cycle), versus today's task-681 cyc12 / task-676 cyc50 churn.
