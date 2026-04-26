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
\* Anchors (OCaml runtime)
\*   - lib/keeper/keeper_execution_receipt.ml: needs_operator_broadcast +
\*     emit_operator_broadcast called from append (this PR's Step 2).
\*   - lib/keeper/keeper_supervisor.ml: stale watchdog fiber forks under
\*     ctx.sw and calls emit_stale_keeper_broadcast (this PR's Step 3).

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

Next ==
  \E k \in Keepers : StartTurn(k) \/ EnterPauseHuman(k)
                     \/ EnterStaleRunning(k) \/ WatchdogEmit(k)
                     \/ Resolve(k)

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
