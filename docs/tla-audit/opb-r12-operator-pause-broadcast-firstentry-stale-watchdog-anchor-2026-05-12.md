# OPB R-12 — OperatorPauseBroadcast.tla: first-entry audit — model accurate; the `keeper_supervisor.ml … emit_stale_keeper_broadcast` anchor drifted (watchdog extracted to `keeper_stale_watchdog.ml` in PR #10670; the OCaml side already flags it) — sub-class 2

**Date**: 2026-05-12 · **Iteration**: 87 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first-entry audit of a previously-unaudited spec)
**Spec**: `specs/keeper-state-machine/OperatorPauseBroadcast.tla` (135 LOC, bug-model paired) — guarantees gate verdicts (`pause_human` / silent stall) are *addressable* (an `OperatorBroadcast` event eventually reaches operators)
**OCaml**: `keeper_execution_receipt.ml` (`needs_operator_broadcast` + `emit_operator_broadcast` called from `append`; `operator_disposition`; `emit_stale_keeper_broadcast`), `keeper_stale_watchdog.ml` (`fork_stale_watchdog` — the watchdog fiber-fork under `ctx.sw`), `keeper_supervisor.ml` (now only `let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog`)
**Verdict**: **Model body accurate (FSM `Idle → Running → {PauseHuman, StaleRunning} → Resolved → Idle`, emit at `EnterPauseHuman`, separate `WatchdogEmit` after `StaleRunning`; matches the runtime — receipt `append` emits a broadcast for PauseHuman/StaleRunning dispositions, the stale watchdog emits independently). One anchor in the "Anchors (OCaml runtime)" block drifted: it cites `lib/keeper/keeper_supervisor.ml: stale watchdog fiber forks under ctx.sw and calls emit_stale_keeper_broadcast` — but PR #10670 extracted the watchdog into `keeper_stale_watchdog.ml` (`fork_stale_watchdog`), `keeper_supervisor.ml` only forwards it, and `emit_stale_keeper_broadcast` is defined in `keeper_execution_receipt.ml` (called from the watchdog's inner `emit_watchdog_broadcast`). The OCaml side already noticed — `keeper_stale_watchdog.ml`'s header comment says "That citation pre-dates PR 10670". Also dropped two stale "this PR's Step 2/3" self-references.** Comment-only fix; model body byte-identical; TLC re-verified (clean = no error, 85 states / 36 distinct, temporal props pass; buggy = error — `Deadlock reached`, see quirk below).

## Why this spec

The iter-81 / iter-85 wrap-ups left a tail of never-first-entry-audited specs; iter 86 took KeeperTurnSlot, this iteration takes OperatorPauseBroadcast (the second-smallest unaudited spec). It models the #10670 fix (gate verdicts were a dead-end display field) — a good audit target because the fix relocated code (supervisor → dedicated watchdog module), which is exactly where anchors drift.

## What was checked

| Spec element | Runtime | Status |
|---|---|---|
| `EnterPauseHuman(k)` emits at the phase transition | `keeper_execution_receipt.ml` — `append` calls `if needs_operator_broadcast disposition then ... emit_operator_broadcast` (`needs_operator_broadcast` true for PauseHuman/StaleRunning-class dispositions) | ✓ accurate |
| `EnterStaleRunning(k)` — no emit (stalled keeper produces no receipt) | matches: a heartbeat-fiber stall produces no receipt → no `append` → no broadcast on its own | ✓ |
| `WatchdogEmit(k)` — separate action that rescues `StaleRunning` from silence | `keeper_stale_watchdog.ml` — `fork_stale_watchdog` forks the watchdog fiber under `ctx.sw`; on stall detection its inner `emit_watchdog_broadcast` calls `Keeper_execution_receipt.emit_stale_keeper_broadcast` | ✓ — **but the anchor pointed at `keeper_supervisor.ml`, which now only forwards (`fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog`)** |
| `operator_disposition` "was a derived display field with no transition out" | `keeper_execution_receipt.ml` — `operator_disposition` still computes the kind/reason; the #10670 fix added the broadcast wiring around it | ✓ (the spec's past-tense framing is historically accurate) |
| `Resolve` / `Recycle` (terminal sink + return to pool) | `keeper_supervisor.ml` flips a keeper back to Idle after the broadcast is acknowledged | ✓ |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (85 states, 36 distinct; `PauseLeadsToBroadcast` + `OperatorPauseEverHandled` temporal props pass); buggy = error (`Deadlock reached`) — re-verified this PR | ✓ — non-zero exit (buggy fails as required), **though the failure mode is a deadlock, not the intended `PauseLeadsToBroadcast` violation** (see follow-up) |
| line-ref drift | none — spec already cites by symbol name | ✓ (only the *file* in one anchor was wrong) |

## The drift (sub-class 2: code relocated, comment/anchor lags)

The "Anchors (OCaml runtime)" block cited:

> `- lib/keeper/keeper_supervisor.ml: stale watchdog fiber forks under ctx.sw and calls emit_stale_keeper_broadcast (this PR's Step 3).`

Two things wrong:
1. **The watchdog fiber-fork moved.** PR #10670 extracted the stale-turn watchdog out of `keeper_supervisor.ml` into a dedicated `keeper_stale_watchdog.ml`. `fork_stale_watchdog` (which does `Eio.Fiber.fork ~sw:ctx.sw …`) lives there now. `keeper_supervisor.ml` only does `let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog` and invokes it once per keeper at boot.
2. **`emit_stale_keeper_broadcast` is in `keeper_execution_receipt.ml`, not `keeper_supervisor.ml`.** The watchdog's inner `emit_watchdog_broadcast` calls `Keeper_execution_receipt.emit_stale_keeper_broadcast`.

This drift is *already documented on the OCaml side*: `keeper_stale_watchdog.ml`'s module header comment reads "watchdog fiber forks under ctx.sw and calls emit_stale_keeper_broadcast. That citation pre-dates PR 10670" — i.e., the OCaml author noticed the spec's anchor was stale and left a note, but the spec itself wasn't updated. This audit closes the loop: the spec anchor now points at `keeper_stale_watchdog.ml: fork_stale_watchdog` (the fiber fork) and notes `emit_stale_keeper_broadcast` is in `keeper_execution_receipt.ml`, with `keeper_supervisor.ml` only forwarding.

Also dropped the two stale "this PR's Step 2 / Step 3" self-references (they referred to the PR that introduced the spec — meaningless now).

**Fix (comment-only)**: rewrote the "Anchors (OCaml runtime)" block — `keeper_execution_receipt.ml` anchor unchanged (still accurate), `keeper_supervisor.ml` anchor replaced with the `keeper_stale_watchdog.ml: fork_stale_watchdog` + `Keeper_execution_receipt.emit_stale_keeper_broadcast` chain + a note on the `keeper_supervisor.ml` forwarding shim + the PR #10670 extraction history; added the iter-64 N-2.a header note.

## Pre-existing follow-up (not fixed here — comment-only PR)

The `-buggy.cfg` says "TLC should report invariant or property violation" but TLC actually reports **`Deadlock reached`**: `SpecBuggy`'s `NextBuggy` drops `WatchdogEmit` *and* `Recycle` and uses `EnterPauseHumanBuggy` (no emit), so every keeper that reaches `PauseHuman`/`StaleRunning` is permanently stuck (`Resolve` needs `emitted[k]`, which never becomes true), and no `NextBuggy` action is enabled → deadlock. That's still a non-zero exit (the buggy spec correctly fails the clean contract), but a cleaner buggy model would keep `Recycle` so the *liveness property* (`PauseLeadsToBroadcast`) violation surfaces directly rather than a deadlock masking it. Same family as the iter-81 observation about `KeeperMemoryLifecycle-buggy.cfg` reporting `TypeOK` instead of the intended `NoSilentLoss`. Candidate for a small spec follow-up (add `Recycle` to `NextBuggy`, or accept the deadlock and reword the cfg comment).

## Sub-class placement & follow-up

- Drift = **sub-class 2 (drift: code relocated, comment/anchor lags)** — confirmed by the OCaml side's own "pre-dates PR 10670" note. Comment-only fix.
- No follow-up PR owed for the anchor fix. Comment-only — model body byte-identical; `specs/INDEX.md` regenerated (OperatorPauseBroadcast content-hash bump `2ef619cbcd73` → `8c678dba2425`). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
- Pre-existing buggy-cfg quirk (deadlock masks the property check) noted above — small spec follow-up candidate, not blocking.
- This is *not* an RFC-gated subsystem (it models the operator-pause-broadcast lifecycle, not credential/keeper_gh/host_config, not repo_manager, not operator_control *credential* handlers — the broadcast is a notification, not an identity/credential action; not keeper_sandbox/shell, not dashboard credential component, not .claude/hooks, not instructions/workflow). RFC-WAIVED.
- **Remaining never-first-entry-audited specs after this**: a handful (KeeperEventQueue, KeeperHeartbeat, KeeperWorkPipeline, KeeperTaskAcquisition, KeeperApprovalQueue — depending on how "audited" is counted; several had partial entries in earlier iterations). Next first-entry candidate: KeeperWorkPipeline or KeeperApprovalQueue.
