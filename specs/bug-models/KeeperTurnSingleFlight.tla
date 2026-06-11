---- MODULE KeeperTurnSingleFlight ----
\* RFC-0225 §3.1: per-keeper turn single-flight admission.
\*
\* Mirrors the runtime [Keeper_turn_admission] (lib/keeper/
\* keeper_turn_admission.ml). Two lanes start keeper turns:
\*
\*   - chat lane  | Keeper_turn.handle_keeper_msg -> run_serialized:
\*                | requests queue (bounded by MaxWaiting =
\*                | max_waiting_chat_requests) and run one at a time.
\*   - autonomous | Keeper_heartbeat_loop_cycle.run_keeper_cycle ->
\*     lane       | run_if_free: a busy slot skips the cycle.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   variable     | OCaml site
\*   -------------+--------------------------------------------------
\*   running[k]   | slot.turn_mu held (0 = free, 1 = one admitted
\*                | turn; 2 is reachable only through the bug actions)
\*   waiting[k]   | slot.waiting (chat requests parked on the slot)
\*
\* The bug actions model the pre-RFC-0225 runtime measured in the
\* 2026-06-10 voice-repeat RCA: Keeper_msg_async forked a daemon per
\* chat request and the heartbeat lane had no in-flight check, so both
\* lanes ran Keeper_agent_run.run_turn concurrently for one keeper
\* (checkpoint clobber, total_turns regression, tool_calls
\* cross-attribution).

EXTENDS TLC, Naturals

CONSTANTS
    Keepers,    \* model keeper names
    MaxWaiting  \* OCaml max_waiting_chat_requests (small in the model)

VARIABLES
    running,    \* keeper -> number of in-flight turns
    waiting     \* keeper -> parked chat requests

vars == << running, waiting >>

TypeOK ==
    /\ running \in [Keepers -> 0..2]
    /\ waiting \in [Keepers -> 0..MaxWaiting]

\* THE invariant of RFC-0225 §3.1: at most one in-flight turn per keeper.
SingleFlight == \A k \in Keepers : running[k] <= 1

Init ==
    /\ running = [k \in Keepers |-> 0]
    /\ waiting = [k \in Keepers |-> 0]

\* A chat request arrives and joins the keeper's queue. Beyond
\* MaxWaiting the runtime rejects with a typed error (state-invisible
\* here: the guard simply disables this action).
ChatEnqueue(k) ==
    /\ waiting[k] < MaxWaiting
    /\ waiting' = [waiting EXCEPT ![k] = @ + 1]
    /\ UNCHANGED running

\* run_serialized acquires the free slot for the head waiter.
ChatAdmit(k) ==
    /\ running[k] = 0
    /\ waiting[k] > 0
    /\ running' = [running EXCEPT ![k] = 1]
    /\ waiting' = [waiting EXCEPT ![k] = @ - 1]

\* run_if_free admits the heartbeat cycle on a free slot. A busy slot
\* skips the cycle, which leaves the state unchanged (stuttering).
AutonomousAdmit(k) ==
    /\ running[k] = 0
    /\ running' = [running EXCEPT ![k] = 1]
    /\ UNCHANGED waiting

\* The admitted turn finishes (normal return, exception, or
\* cancellation — every release path of run_locked).
TurnComplete(k) ==
    /\ running[k] > 0
    /\ running' = [running EXCEPT ![k] = @ - 1]
    /\ UNCHANGED waiting

Next ==
    \E k \in Keepers :
        \/ ChatEnqueue(k)
        \/ ChatAdmit(k)
        \/ AutonomousAdmit(k)
        \/ TurnComplete(k)

Spec == Init /\ [][Next]_vars

\* Bug: the pre-RFC chat lane (Keeper_msg_async fork_daemon per
\* request) starts the queued turn without passing admission, even
\* while another turn is in flight. SingleFlight MUST be violated.
BuggyChatBypass(k) ==
    /\ waiting[k] > 0
    /\ running[k] < 2
    /\ running' = [running EXCEPT ![k] = @ + 1]
    /\ waiting' = [waiting EXCEPT ![k] = @ - 1]

\* Bug: the pre-RFC heartbeat lane starts a scheduled cycle with no
\* in-flight check (keeper_turn.ml had none before RFC-0225).
BuggyAutonomousBypass(k) ==
    /\ running[k] = 1
    /\ running' = [running EXCEPT ![k] = 2]
    /\ UNCHANGED waiting

NextBuggy ==
    \E k \in Keepers :
        \/ ChatEnqueue(k)
        \/ ChatAdmit(k)
        \/ AutonomousAdmit(k)
        \/ TurnComplete(k)
        \/ BuggyChatBypass(k)
        \/ BuggyAutonomousBypass(k)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
