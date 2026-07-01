# RFC-0302 — Stimulus-gated Keeper Wake (retire self-cadence no-progress detect/pause/tombstone)

- Status: Draft
- Area: `lib/keeper/` (keeper lifecycle, heartbeat/keepalive wake, no-progress loop, wake-tombstone), `lib/dashboard/` (attention projection)
- Supersedes: RFC-0246 (Wake-cascade Recovery Tombstone) — inverts its remedy
- Builds on / touches: RFC-0239 (no-progress), RFC-0020 (typed wake carrier), RFC-0246 (tombstone)
- Evidence (code, main `f13346d9fd8`):
  - self-cadence wake exists: `lib/keeper/keeper_heartbeat_loop_scheduling.ml:50` — *"a no-progress loop kept re-waking on its OWN self-cadence clock"*; `:59` `self_cadence_wake`; `:64` `wake_tombstone_decide ~origin:Self_cadence`
  - progress judged by heuristic, not LLM: `lib/keeper/keeper_agent_run_turn_helpers.ml:155` `all_class Passive_status → Contract_passive_only`; `lib/keeper/keeper_unified_turn_success.ml:250` `made_progress = turn_made_progress ~strong_evidence ~surface_requires_evidence`
  - heuristic drives an actual PAUSE: `lib/keeper/keeper_unified_turn_success.ml:245-248` — *"persistent idle loop … is paused for operator resume (mark_loop_detected) … arms the self-cadence wake-tombstone"*
  - suppression stack: `lib/keeper/keeper_no_progress_loop_detector.ml` (streak/latch), `lib/keeper/keeper_wake_tombstone.ml` (RFC-0246; suppresses Board_reactive/Heartbeat; Operator_direct/@mention bypass)
  - runtime already says passive ≠ attention: `lib/keeper/keeper_unified_turn_success.ml:305` `Contract_passive_only → None`
  - but dashboard still escalates it: `lib/dashboard/dashboard_goals_types_builder.ml:172` `needs_attention = not (disposition = "Pass")`; passive_only → display `Blocked`
  - live snapshot (`/api/v1/dashboard/bootstrap`, 14 keepers, 2026-07-01): 4/14 `needs_attention=true`; `albini` mislabeled `Blocked` via `attention_reason:"completion_contract_result:passive_only"` while `status:idle`

## Summary

Two independent errors compound here:

1. **"No-progress" is not a real turn outcome.** An LLM agent handed instructions + a prompt always produces *something* — a tool call, text, or at minimum reasoning/thinking and a decision (including a decision to defer). The `made_progress : bool` per-turn classification is a **category error**: it counts only a few tool-classes as "progress" and relabels genuine activity (thinking, deciding, posting, choosing to wait) as "nothing happened." The only turn that truly produces nothing is a **runtime empty-reply failure** (the model emitted no output) — that is a runtime bug to fix at the model boundary, not a keeper lifecycle state.
2. **Keepers wake on a blind self-cadence timer** with no stimulus, which is what manufactures the "passive" turns the heuristic then flags.

The current stack layers a fix on the symptom: a heuristic classifies a turn as no-progress, a detector **latches** after a streak, the keeper is **paused**, and a **tombstone** suppresses the very wakes the system emitted.

This RFC removes both roots: **(a) delete the per-turn progress classification** — a turn is activity by definition; goal *advancement* is a semantic question owned asynchronously by the goal/verification layer (an LLM boundary), never a per-turn boolean that gates wake or pause. **(b) gate wakes on a real stimulus/opportunity before spending a turn.** With no unprompted wakes and no manufactured "no-progress" state, the passive-only classification, the no-progress detector, the pause, and the tombstone (RFC-0246) all become unnecessary and are retired.

## Motivation

### "No-progress" is a manufactured state

Given a prompt, an agent turn always yields output: a tool call, a text reply, or reasoning/thinking plus a decision. `Contract_passive_only` is produced by `all_class Passive_status` (`keeper_agent_run_turn_helpers.ml:155`) — i.e. "every tool this turn was in the *passive* class." That is not "did nothing"; it is "did things I chose not to count." Thinking, deciding to defer (`last_speech_act = defer`), posting to the board, choosing to wait for a human — all real activity, all relabeled as no-progress. The system then forces this fiction into a lifecycle **state** (latch → pause → tombstone). There is no state to create.

The only genuine "nothing happened" is a **runtime empty-reply** (model emitted no visible output — the known `thinking_only + idle-spin` failure). That is a defect at the model/runtime boundary to be surfaced and fixed as an error, not a keeper state to latch and pause. So even the edge case does not justify a per-turn progress boolean.

Corollary: goal *advancement* ("did this bring the goal closer?") is a real but **semantic** question. It belongs to the goal/verification layer as an async LLM judgment, decoupled from the turn loop — not `made_progress : bool` computed from tool-classes and wired into wake/pause.

### The loop is circular (band-aid on a self-inflicted wound)

1. A keeper self-wakes on its cadence clock with no stimulus (`keeper_heartbeat_loop_scheduling.ml:50`).
2. Nothing to do → a **passive** turn → `made_progress = false` (heuristic, `keeper_unified_turn_success.ml:250`).
3. Re-wakes on cadence → repeats → thrash.
4. `keeper_no_progress_loop_detector` latches after streak → keeper **paused** (`:245-248`).
5. `keeper_wake_tombstone` (RFC-0246) suppresses the Heartbeat/Board_reactive wakes the system itself emitted.

The system wakes for no reason → detects it did nothing → suppresses its own wake. RFC-0246 named the symptom correctly but treated it with a suppression gate (a cap/cooldown-class remedy; it even cites OpenClaw's "recovery-tombstone pattern"). Per the project's workaround bar, cooldown/dedup/repair suppress symptoms; the root here is the unprompted wake.

### Two principle violations

| Site | What it is | Violates |
|---|---|---|
| `Contract_passive_only` = `all_class Passive_status`, `made_progress` = `strong_evidence`/`surface_requires_evidence` | tool-class / boolean **heuristic** judging "meaningful progress" | "판단이 들어가면 무조건 LLM 경계" (no heuristic judgment) |
| no-progress latch → `mark_loop_detected` → **pause** + tombstone | heuristic drives an actual keeper **pause** | "Pause는 진짜 망가진 것만; 제약이 Pause/Stop이 되면 안 됨 — 다른 활동을 하게 하라" |

### Layer disagreement (already half-fixed)

The runtime already decided passive is not an attention/failure event (`keeper_unified_turn_success.ml:305` → `None`), but the dashboard still projects it as `Blocked`/`needs_attention` (`dashboard_goals_types_builder.ml:172`). Operators see "주의" walls for keepers that are simply idle. The two layers must resolve to one truth (SSOT).

### Why not "improve the heuristic" or "delete `Contract_passive_only`"

- Improving the classifier keeps a heuristic where the project wants an LLM/stimulus boundary.
- Deleting the variant naively lets passive turns fall through the producer ladder (`keeper_agent_run_turn_helpers.ml:150-160`) to `Contract_unknown`, i.e. the "unknown → attention" anti-pattern — worse, not better.
- The real anti-spin protection is on the `made_progress` path, not on `Contract_passive_only`; removing the variant alone does not fix the pause.

## Design

### Principle: gate before, not detect after

A keeper turn is spent **only when a stimulus/opportunity exists**. "Nothing to do" resolves to *stay idle*, never *pause* and never *spend a passive turn*.

### 1. Typed wake trigger (stimulus, not timer)

Replace the unconditional self-cadence turn request with a typed trigger that carries *why* the keeper is waking:

```ocaml
type wake_trigger =
  | Message of { channel : channel_id; ... }      (* Discord/Slack/gate inbound *)
  | Mention of { source : mention_source }
  | Task_available of { task_id : string }
  | Board_activity of { post_id : string; relation : board_relation }
  | Schedule_fired of { schedule_id : string }
  | Long_job_done of { job_id : string }
  | Operator_direct
```

There is **no `Self_cadence` constructor**: a keeper does not wake itself on a blind clock. Proactive behavior is expressed as `Board_activity`/`Task_available`/`Schedule_fired` — an *opportunity*, not a timer tick.

### 2. Where judgment lives = LLM boundary

When "is this stimulus worth a full turn?" genuinely needs judgment (e.g. a borderline board post), that decision is made behind an **LLM boundary**, not `all_class Passive_status`. Deterministic stimuli (a direct message, a fired schedule, an available claimed task) bypass judgment and wake directly.

### 3. Delete the per-turn progress judgment

There is no `made_progress : bool` and no "did this turn progress?" gate. A completed turn is activity, full stop.

- `made_progress` (`keeper_unified_turn_success.ml:250`) and its feed into the loop detector → **deleted**.
- `Contract_passive_only` (`keeper_agent_run_turn_helpers.ml:155`) → **deleted** as a lifecycle signal (kept, if at all, only as inert display telemetry that feeds nothing).
- Goal advancement is assessed by the goal/verification layer as an async LLM judgment, never on the turn hot path.

### 4. The only real "nothing" = runtime empty-reply error

An empty-reply / `thinking_only` turn (model produced no visible output) is handled at the **runtime boundary** as a typed error (retry / next-runtime / surface to operator), not classified as keeper "no-progress" and not latched. This is the single legitimate case the old detector was groping at, and it belongs to the runtime, not the lifecycle FSM.

### 5. Retire the after-the-fact stack

With no unprompted wakes and no progress classification:

- `keeper_no_progress_loop_detector` latch → **no pause**.
- `keeper_wake_tombstone` (RFC-0246) → removed; there is no self-emitted wake to suppress. `Operator_direct`/`Mention` were already exempt, i.e. the tombstone only ever suppressed machine-emitted wakes.
- dashboard `needs_attention` for passive/no-progress → removed; align with runtime.

### 4. Idle is a first-class, cheap state

A keeper with no pending `wake_trigger` sits in `Idle` and consumes no turns until a trigger arrives. This is the project's stated model ("장기작업은 올려두고 끝나면 Wake Up"; "특정 시간과 조건에 맞춰 Wake Up").

## Migration (phased — safe first, reversible)

- **Phase 0 (dashboard align, low risk, no runtime change):** stop the dashboard escalating `passive_only`/no-progress to `needs_attention`. Do **not** invent a "무진행" badge — there is no such state; show the keeper's actual last activity (last tool / thinking / `defer`). Fixes the operator-visible "주의" walls immediately.
- **Phase 1 (instrument):** log every keeper wake with its origin. Measure how many wakes are `Self_cadence` and how often they fire with no stimulus. Quantifies the thrash the stack exists to absorb.
- **Phase 2 (stimulus-gate + delete progress boolean):** require a concrete stimulus/opportunity before a self-cadence turn runs (deterministic stimuli bypass; LLM boundary for borderline opportunities). Delete `made_progress` and the per-turn progress classification. Route empty-reply to the runtime error path.
- **Phase 3 (retire stack):** with Phase 2 shown to eliminate unprompted wakes, remove the no-progress pause + tombstone (RFC-0246).

## Verification

- TLA+ bug-model (per project pattern): model `SelfCadenceWakeWithNoStimulus` as a `BugAction`; invariant `NoTurnWithoutStimulus` must hold on the clean spec and be violated on the buggy spec.
- Metric gate: Phase-1 telemetry — target `self_cadence_passive_turns / total_turns → 0` after Phase 2.
- Regression tests: keeper stays `Idle` (not `Paused`) across N cadence intervals with no stimulus; a real stimulus wakes it exactly once.

## Risks / rollback

- **Proactivity loss:** if opportunity detection is too strict, keepers go quiet. Mitigation: Phase-1 measurement sets the opportunity threshold from data; LLM boundary for borderline cases.
- **RFC-0246 is operator's active area (#22710/#22892 landed 2026-07-01).** This RFC must be reviewed with that author; Phases are independently revertible (each is its own PR).
- Rollback: Phase 3 is last and gated on Phase-2 evidence; reverting Phase 3 restores the tombstone.

## Open questions

1. Is any legitimate purpose served by a blind self-cadence wake that a typed opportunity trigger cannot express? (Current belief: no.)
2. Should `Contract_passive_only` survive as inert telemetry, or be deleted once nothing consumes it for a decision?
