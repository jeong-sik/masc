---- MODULE OperatorPauseBroadcast ----
\* Operator Pause Broadcast — guarantees gate verdicts are addressable
\*
\* Bug class
\*   keeper_execution_receipt.operator_disposition was a derived display
\*   field with no transition out: a "pause_human" verdict simply turned
\*   a dashboard chip red and no event reached operators or supervisor.
\*   Symmetrically, KSM=Running keepers whose heartbeat fiber blocked on
\*   a long call produced no receipt at all — silent stall.
\*
\* Property under audit
\*   For every keeper that enters PauseHuman or StaleRunning, an
\*   OperatorBroadcast event is eventually emitted (leads-to). The clean
\*   model satisfies this; the bug model (where emit is silently dropped)
\*   must violate it.
\*
\* Anchors (OCaml runtime — cited by symbol/function name, not line
\* number; iter 64 N-2.a convention)
\*   - keeper_execution_receipt.ml: [needs_operator_broadcast] +
\*     [emit_operator_broadcast], called from [append]
\*     (`if needs_operator_broadcast disposition then ... emit_operator_broadcast`).
\*     This is the EnterPauseHuman emit path.
\*   - keeper_stale_watchdog.ml: [fork_stale_watchdog] forks the
\*     stale-turn watchdog fiber under [ctx.sw] and (via its inner
\*     [emit_watchdog_broadcast]) calls
\*     [Keeper_execution_receipt.emit_stale_keeper_broadcast].  This is
\*     the WatchdogEmit path.  keeper_supervisor.ml only *forwards*:
\*     `let fork_stale_watchdog = Keeper_stale_watchdog.fork_stale_watchdog`,
\*     invoked once per keeper at supervisor boot.  (The watchdog logic
\*     was extracted out of keeper_supervisor.ml into keeper_stale_watchdog.ml
\*     in PR #10670; the OCaml module's own header comment already flags
\*     that the old "keeper_supervisor.ml ... emit_stale_keeper_broadcast"
\*     citation here was stale — this updates the spec side to match.)

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Keepers

VARIABLES
  phase,            \* keeper -> {Idle, Running, PauseHuman, StaleRunning, Resolved}
  emitted           \* keeper -> BOOLEAN  (broadcast already emitted)

vars == <<phase, emitted>>

Phases == {"Idle", "Running", "PauseHuman", "StaleRunning", "Resolved"}

TypeOK ==
  /\ phase \in [Keepers -> Phases]
  /\ emitted \in [Keepers -> BOOLEAN]

Init ==
  /\ phase = [k \in Keepers |-> "Idle"]
  /\ emitted = [k \in Keepers |-> FALSE]

\* A keeper picks up work.
StartTurn(k) ==
  /\ phase[k] = "Idle"
  /\ phase' = [phase EXCEPT ![k] = "Running"]
  /\ UNCHANGED emitted

\* Operator gate fails (tool_required_unsatisfied / api_error / unknown).
\* Receipt is appended; new code path emits broadcast.
EnterPauseHuman(k) ==
  /\ phase[k] = "Running"
  /\ phase' = [phase EXCEPT ![k] = "PauseHuman"]
  /\ emitted' = [emitted EXCEPT ![k] = TRUE]      \* Step 2 emit

\* Heartbeat fiber blocks; no receipt. Watchdog is the only path that
\* rescues this from silence.
EnterStaleRunning(k) ==
  /\ phase[k] = "Running"
  /\ phase' = [phase EXCEPT ![k] = "StaleRunning"]
  /\ UNCHANGED emitted

WatchdogEmit(k) ==
  /\ phase[k] = "StaleRunning"
  /\ ~emitted[k]
  /\ emitted' = [emitted EXCEPT ![k] = TRUE]      \* Step 3 emit
  /\ UNCHANGED phase

\* Operator acts on broadcast (out of scope: just terminal sink).
Resolve(k) ==
  /\ emitted[k]
  /\ phase[k] \in {"PauseHuman", "StaleRunning"}
  /\ phase' = [phase EXCEPT ![k] = "Resolved"]
  /\ UNCHANGED emitted

\* After resolution, the keeper returns to the work pool to accept the
\* next turn. Without this transition every behavior in which all
\* keepers reach "Resolved" deadlocks (no action is enabled), which TLC
\* reports as a spec error rather than a property failure (exit 11).
\* The runtime models exactly this recycle: keeper_supervisor flips a
\* keeper back to Idle after the operator broadcast is acknowledged.
\* emitted is reset to FALSE so the leads-to property is meaningful for
\* subsequent turns of the same keeper rather than trivially carrying
\* over a stale TRUE.
Recycle(k) ==
  /\ phase[k] = "Resolved"
  /\ phase' = [phase EXCEPT ![k] = "Idle"]
  /\ emitted' = [emitted EXCEPT ![k] = FALSE]

Next ==
  \E k \in Keepers : StartTurn(k) \/ EnterPauseHuman(k)
                     \/ EnterStaleRunning(k) \/ WatchdogEmit(k)
                     \/ Resolve(k) \/ Recycle(k)

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ \A k \in Keepers : WF_vars(WatchdogEmit(k))
  /\ \A k \in Keepers : WF_vars(Resolve(k))

\* === Bug Model ===========================================================
\* Models the pre-fix behavior: PauseHuman emit is silently dropped,
\* watchdog emit absent. This must violate the safety/liveness pair.

EnterPauseHumanBuggy(k) ==
  /\ phase[k] = "Running"
  /\ phase' = [phase EXCEPT ![k] = "PauseHuman"]
  /\ UNCHANGED emitted                     \* note: no emit

NextBuggy ==
  \E k \in Keepers : StartTurn(k) \/ EnterPauseHumanBuggy(k)
                     \/ EnterStaleRunning(k) \/ Resolve(k)

SpecBuggy ==
  /\ Init
  /\ [][NextBuggy]_vars

\* === Properties ==========================================================

\* Safety (per-step). A keeper that has reached PauseHuman or StaleRunning
\* must not advance past those phases (toward Resolved) without first
\* emitting. emitted is monotone-increasing.
EmittedBeforeResolved ==
  \A k \in Keepers : phase[k] = "Resolved" => emitted[k]

\* Liveness. A pause/stall always leads to an emitted broadcast.
PauseLeadsToBroadcast ==
  \A k \in Keepers :
    (phase[k] \in {"PauseHuman", "StaleRunning"}) ~> emitted[k]

\* Composite invariant the user actually cares about: the gate verdict
\* never sits silent forever.
OperatorPauseEverHandled == PauseLeadsToBroadcast

============================================================================
