---
rfc: "0263"
title: "Owner-priority cooperative preemption of in-flight autonomous turns"
status: Draft
created: 2026-06-19
updated: 2026-06-19
author: vincent
supersedes: []
superseded_by: null
related: ["0225", "0230", "0220", "0153"]
implementation_prs: []
---

# RFC-0263: Owner-priority cooperative preemption of in-flight autonomous turns

Status: Draft · Live-lane priority inversion · Closes the preemption gap RFC-0225 left as a non-goal
Drafted by: Claude Opus 4.8 (adversarial triage session 2026-06-19), pending owner review.
Grounding source: read against the working tree at `5c4e87dd6c` (origin/main, 2026-06-19); issue #20849 adversarially triaged in workflow `wgdppqj7p` (triage → skeptic-verify, both verdict `live`, fix_is_sound true).

> Anchors marked **(verified)** were read against the working tree on 2026-06-19. File:line references are to that tree and must be re-checked before implementation.

---

## §1 Problem — a structural priority inversion (issue #20849)

An autonomous keeper turn holds the per-keeper turn slot and blocks an Owner direct message for 17+ minutes, while the dashboard "stream stall" warning misreads in-flight tool-grinding as a dead keeper.

The inversion is structural, not a transient bug:

- The per-keeper turn slot (`lib/keeper/keeper_turn_admission.ml`, RFC-0225 §3.1 single-flight) is **non-preemptive**. An autonomous turn admitted via `run_if_free` (`Eio.Mutex.try_lock`, l.85 **(verified)**) holds `turn_mu` across the **entire** multi-step tool loop in `run_locked` (l.66-83 **(verified)**), bounded only by `turn_timeout_sec` (default 600s / hard ceiling 900s) and `max_turns`.
- An Owner DM admitted via `run_serialized` (`Eio.Mutex.lock`, FIFO wait, l.92 **(verified)**) — the single live caller is `keeper_turn.ml:959` `handle_keeper_msg` (Chat lane) **(verified)**. It simply FIFO-waits on `turn_mu`.
- The chat consumer additionally **parks** queued DMs while a turn is in flight: `keeper_chat_consumer.ml` `match in_flight with Some _ -> () (* leave queued *) | None -> dequeue` **(verified)**.
- The autonomous lane (`keeper_heartbeat_loop_cycle.ml:136` `run_keeper_cycle` → `run_if_free` **(verified)**) claims the slot with **no check for a waiting chat request**; on `` `Busy `` it only logs and skips.
- World-observation priority (`keeper_world_observation.ml:695-736`, Reactive > Scheduled_autonomous at l.725 **(verified)**) applies **only when choosing the next turn while the slot is free** — it cannot preempt an already-in-flight turn. And a 1:1 dashboard DM flows through `Keeper_chat_queue`, not `pending_mentions`/`pending_scope_messages`, so it is not even a reactive trigger; it parks behind `in_flight`.

**Consequence:** owner interactive signals have **zero priority** over autonomous busywork once a turn is in flight, regardless of channel. That is #20849.

### 1.1 Secondary (cosmetic) — the stream-stall misread

The dashboard "스트림 지연" warning (`dashboard/src/components/chat/primitives.ts:2195`, threshold 15s, `isStalled` requires `streaming && lastEventAt`, l.1885/1985 **(verified)**) is an SSE-staleness heuristic that renders only during active streaming. It is **not** the priority-inversion root and is addressed separately (§3.4) — surfacing in-flight tool activity so a QUEUED message is not read as a dead keeper.

---

## §2 Scope boundary vs RFC-0225 / RFC-0230 / RFC-0220

| Concern | Owner |
|---------|-------|
| Single-flight admission (at most one in-flight turn per keeper) | RFC-0225 (its §2 non-goal: *"Not a turn scheduler redesign"*) |
| Wake policy (when a keeper starts a turn) | RFC-0230 |
| Scheduling decouple + keeper liveness (I1: a keeper must never permanently stop) | RFC-0220 |
| **In-flight preemption / owner-priority over a running autonomous turn** | **This RFC (0263)** |

RFC-0225 intentionally made chat **queue** rather than reject (its §3.1: *"the dashboard user expects a reply"*). Queuing is correct; **unbounded-latency** queuing behind a 17-minute autonomous turn is the gap. Grounded: `rg 'preempt|interrupt|priority invers|owner.*priority|cancel.*autonomous' docs/rfc/RFC-0225* docs/rfc/RFC-0230*` → **no matches (verified)**. Preemption is unspecified and unimplemented.

**Non-goals:** turn scheduler redesign; relaxing single-flight (0225's at-most-one-in-flight invariant is preserved — this RFC never runs two turns concurrently); the cosmetic stall indicator (§3.4 is a separate cosmetic track).

---

## §3 Design — owner-priority cooperative yield

### 3.1 Chat-waiting signal (admission layer)

The slot already tracks `waiting` (the FIFO depth, guarded by `state_mu`, incremented in `run_serialized` l.105-110 **(verified)**). Expose it as a read for the in-flight turn:

```ocaml
val chat_waiting : base_path:string -> keeper_name:string -> bool
(* true iff a Chat-lane caller is currently FIFO-waiting on this slot *)
```

No new state — this surfaces the existing counter. (Open question §6.3: signal on any Chat-lane waiter vs an owner-specific predicate.)

### 3.2 Cooperative yield = graceful early-finalize (NOT a mid-turn mutex handoff)

The critical safety property: **`turn_mu` is never released mid-turn.** Releasing the slot between an LLM call and the post-turn checkpoint is exactly the concurrency window RFC-0225 §1 was created to close (checkpoint clobber, `total_turns` regression). So yield is structured as an **early, *graceful* turn termination**, reusing the normal finalize path:

1. `keeper_unified_turn_execution.run` checks `chat_waiting` at a **tool-loop step boundary** — the natural checkpoint between LLM calls, where no tool result is half-applied.
2. If a chat caller is waiting, the autonomous turn **stops accepting new tool steps and finalizes normally**: the standard finalize + RFC-0225 §3.2 versioned-CAS checkpoint runs, so the partial progress is persisted exactly as a normally-completed short turn would be.
3. `run_locked` then releases `turn_mu` on the normal return path (l.77-79 **(verified)**), and the queued chat turn is admitted by the waiting `run_serialized`.
4. The autonomous lane resumes its remaining work on the **next heartbeat** (RFC-0220 I1 liveness guarantees the keeper is rescheduled).

This is **abort-free**: there is no `Eio.Cancel`, no half-applied tool, no mutex handoff. The partial autonomous turn is indistinguishable from a turn that simply chose to stop early — a state the system already handles.

### 3.3 Admission-time suppression (optional, secondary)

`keeper_world_observation` may suppress a **new** `Scheduled_autonomous` decision when chat-queue depth > 0, extending the existing Reactive > Scheduled priority (l.725) to the pre-admission point so a fresh autonomous turn does not grab the slot ahead of a pending owner message. This is backpressure shaped, but it acts on a **real pending-owner signal**, not an arbitrary cap/cooldown — and it is strictly secondary to §3.2 (which handles the already-in-flight case).

### 3.4 Dashboard tool-activity surfacing (cosmetic, separate track)

Surface in-flight tool activity (last tool-call time, call count) for a QUEUED message so tool-grinding is not rendered as "dead" (`primitives.ts` / `keeper-state.ts`). Cosmetic; does not touch the inversion.

---

## §4 Boundary — MASC policy vs OAS mechanism

The hard boundary question (issue triage flagged this): the tool loop runs partly in OAS territory (the agent turn), while the preemption *policy* is MASC-specific.

- **MASC owns the policy:** `keeper_turn_admission.chat_waiting` (the signal) and the decision to stop early live in `lib/keeper` (`keeper_unified_turn_execution`).
- **OAS owns only the mechanism:** OAS must expose a *yield point* — a way for the turn loop to be told "finalize after the current step instead of continuing." This is a generic early-stop hook (analogous to `max_turns` reached), **not** a MASC concept. OAS must remain ignorant of keepers, chat lanes, and admission (the OAS↔MASC boundary the project mandates).
- If OAS cannot expose a step-boundary stop hook cleanly, the MASC-side fallback is to dynamically lower the effective `max_turns`/step budget for the in-flight turn — same effect (early graceful finalize) without an OAS API change. (Open question §6.4.)

---

## §5 Why this is not a workaround (CLAUDE.md gate self-check)

| signature | applies? | why |
|-----------|----------|-----|
| Telemetry-as-fix | No | `chat_waiting` surfaces an existing counter to **drive preemption**, not to merely observe a drop. |
| String/substring classifier | No | No string matching; the signal is a typed slot read. |
| N-of-M patch | No | One signal + one boundary check + one finalize path. |
| Cap / cooldown / dedup / repair | Partial (§3.3 only) | §3.3 is backpressure on a real pending-owner signal, RFC-gated, and secondary to §3.2; §3.2 (the primary fix) is not cap/cooldown. |
| catch-all `_ ->` | No | None added. |
| test backdoor | No | None. |
| same fix N sites | No | Single yield point. |

The primary fix is a **structural address of the non-preemptive hold** via the existing graceful-finalize path — not symptom suppression. fix_is_sound was independently confirmed by the skeptic verifier.

---

## §6 Open questions (owner decisions)

1. **Yield granularity / fairness.** Check `chat_waiting` at every tool-loop boundary, or once per turn, or only after a minimum autonomous progress? Checking every boundary minimizes owner latency but, under continuous chat, could starve autonomous work — the **reverse** inversion. A min-progress floor or per-turn-single-yield bounds it.
2. **Yield vs abort.** This RFC chooses graceful early-finalize (§3.2). Confirm there is no requirement for hard cancellation (which would risk the RFC-0225 regression).
3. **Owner-specific vs any-chat priority.** Preempt for any Chat-lane waiter, or only for an owner/operator-tagged DM? The reported repro is a dashboard DM; a finer predicate avoids peer-chat preempting autonomous work unnecessarily.
4. **OAS yield mechanism.** Does OAS expose (or accept) a step-boundary early-stop hook, or does MASC implement yield purely via a dynamic step-budget reduction (§4)?
5. **Resume guarantee.** Confirm the early-finalized autonomous work is reliably resumed by the next heartbeat (RFC-0220 §3.3 liveness) and not dropped.

---

## §7 Boundaries (manifesto)

- **Declarative:** the priority policy (owner over autonomous) is declared.
- **Deterministic:** the boundary check + graceful finalize is deterministic; no LLM in the yield decision.
- **Non-deterministic:** the LLM does the turn's work; it does not decide preemption.

Preemption **policy** is MASC; the **mechanism** (a step-boundary stop) is a generic OAS capability. OAS never learns about chat lanes.

---

## §8 Test plan

- **Concurrency:** start a long fake autonomous turn, inject a chat request; assert the chat turn is admitted within **one tool-loop boundary**, not after `turn_timeout_sec`. Assert at-most-one-in-flight (RFC-0225 invariant) holds throughout.
- **Property (regression safety):** every yield goes through finalize + versioned checkpoint — checkpoint never clobbered, `total_turns` monotonic (the RFC-0225 §3.2 invariants must still hold under yield).
- **Fairness:** under continuous chat, the autonomous turn eventually completes (no reverse starvation) — exercises the §6.1 granularity choice.
- **TLA+ bug model** (CLAUDE.md §TLA+): (a) `BugAction = MidTurnMutexHandoff`, invariant `YieldAlwaysFinalizesBeforeRelease` violated under `NextBuggy`, holds under clean `Next`; (b) `BugAction = NoOwnerPreemption`, invariant `OwnerAdmittedWithinOneBoundary` (an owner waiter is admitted within one tool-loop step of signalling) violated under the current code, holds under the fix.

---

## §9 Rollout

1. `chat_waiting` signal exposed in admission (inert).
2. `keeper_unified_turn_execution` boundary check + graceful early-finalize (the behavior change; the core of #20849).
3. Admission-time suppression (§3.3, optional, independent).
4. Dashboard tool-activity surfacing (§3.4, cosmetic, independent).

The metric that proves 0263 worked: **owner-DM admission latency p99 drops from `~turn_timeout` to ~one tool-step**, with zero checkpoint-clobber / `total_turns` regressions (RFC-0225 invariants intact).
