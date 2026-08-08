---- MODULE AgentLifecycle ----
\* Models lib/agent/agent_lifecycle.mli FSM directly.
\*
\* States:
\*   Accepted, Ready, Running, Completed, Failed
\*
\* Allowed transitions (per .mli docstring):
\*   Accepted  -> Ready | Failed
\*   Ready     -> Running | Failed
\*   Running   -> Ready | Completed | Failed
\*   Completed -> (terminal)
\*   Failed    -> (terminal)
\* Same-state reaffirm allowed on non-terminal states.
\*
\* Verifies:
\*   1. TypeOK
\*   2. TerminalIsStable: terminal status never transitions
\*   3. NoIllegalTransition: declared transitions are exhaustive
\*   4. RunningRequiresReady: Running entered only from Ready or via reaffirm
\*   5. CompletedRequiresRunning: Completed reached only from Running
\*   6. NoTransitionIntoAccepted: prev != Accepted -> status != Accepted
\*
\* Maps 1:1 to OCaml types:
\*   lifecycle_status = Accepted | Ready | Running | Completed | Failed
\*
\* Cancellation absorption is NOT modeled here — cancellation lives at the
\* fiber/Switch layer (agent_turn, runtime), not in the lifecycle FSM.
\* A separate spec (AgentCancellation.tla) should model that.
\*
\* Design note: state representation uses only (status, prev_status). The
\* Ready <-> Running cycle is unbounded; no runtime turn limit is modeled.
\*
\* @since (issue #1212)

EXTENDS FiniteSets

VARIABLES
    status,         \* Current lifecycle state
    prev_status     \* Status that immediately preceded `status` ("None" before any transition)

vars == <<status, prev_status>>

States       == {"Accepted", "Ready", "Running", "Completed", "Failed"}
StatesOrNone == States \cup {"None"}

NonTerminal == {"Accepted", "Ready", "Running"}
Terminal    == {"Completed", "Failed"}

TypeOK ==
    /\ status \in States
    /\ prev_status \in StatesOrNone

\* ── Helpers ──────────────────────────────────
IsTerminal(s) == s \in Terminal

\* Allowed next-state set per .mli (excluding same-state reaffirm).
AllowedNext(s) ==
    CASE s = "Accepted"  -> {"Ready", "Failed"}
      [] s = "Ready"     -> {"Running", "Failed"}
      [] s = "Running"   -> {"Ready", "Completed", "Failed"}
      [] s = "Completed" -> {}
      [] s = "Failed"    -> {}

\* ── Initial state ────────────────────────────
Init ==
    /\ status = "Accepted"
    /\ prev_status = "None"

\* ── Transition actions ───────────────────────
\* Forward transition to a different state.
Transition(to_) ==
    /\ ~IsTerminal(status)
    /\ to_ # status                                  \* not a reaffirm — Reaffirm action handles that
    /\ to_ \in AllowedNext(status)
    /\ prev_status' = status
    /\ status' = to_

\* Same-state reaffirm: allowed on non-terminal states (per .mli line 13–14).
\* Idempotent — does not change observable state.
Reaffirm ==
    /\ ~IsTerminal(status)
    /\ UNCHANGED vars

\* Stutter on terminal states.
StutterTerminal ==
    /\ IsTerminal(status)
    /\ UNCHANGED vars

Next ==
    \/ \E to_ \in States : Transition(to_)
    \/ Reaffirm
    \/ StutterTerminal

Spec == Init /\ [][Next]_vars /\ WF_vars(\E to_ \in States : Transition(to_))

\* ── Safety Invariants ────────────────────────

\* 1. PrevNotEqualStatus: prev_status differs from status (when set).
\*    Enforced by Transition action (to_ # status); validates the model.
PrevNotEqualStatus ==
    prev_status # "None" => prev_status # status

\* 2. TerminalIsStable: once terminal, status never changes.
\*    Expressed as: if prev_status is terminal, current status equals prev_status.
\*    (Terminal has no outgoing transitions, so the next-state must be reaffirm/stutter.)
TerminalIsStable ==
    IsTerminal(prev_status) => status = prev_status

\* 3. NoIllegalTransition: every transition arrow is declared.
NoIllegalTransition ==
    prev_status # "None" =>
        status \in AllowedNext(prev_status)

\* 4. RunningRequiresReady: Running can only be reached from Ready
\*    (since Reaffirm doesn't change status, prev_status holds the actual predecessor).
RunningRequiresReady ==
    status = "Running" =>
        (prev_status = "None" \/ prev_status = "Ready")

\* 5. CompletedRequiresRunning: Completed reachable only from Running.
CompletedRequiresRunning ==
    status = "Completed" => prev_status = "Running"

\* 6. NoTransitionIntoAccepted: AllowedNext never produces Accepted.
\*    So once we leave Accepted, we cannot return.
NoTransitionIntoAccepted ==
    (status = "Accepted") => (prev_status \in {"None", "Accepted"})

\* ── Bug Model: Terminal Resurrection ───────────
\* Models a regression where a terminal status (Failed) is incorrectly
\* re-transitioned to Running — e.g. a buggy checkpoint restore that
\* ignores `is_terminal`.
\*
\* SHOULD violate TerminalIsStable.

BugTerminalResurrection ==
    /\ status = "Failed"
    /\ prev_status' = "Failed"
    /\ status' = "Running"

NextBuggy ==
    \/ \E to_ \in States : Transition(to_)
    \/ Reaffirm
    \/ StutterTerminal
    \/ BugTerminalResurrection

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(\E to_ \in States : Transition(to_))

\* Invariant SHOULD be violated under SpecBuggy.
TerminalIsStableMustHold == TerminalIsStable

====
