---- MODULE KeeperTaskInterlock ----
\* Bug Model: Keeper FSM and Task FSM must stay interlocked across
\* a Dead transition.
\*
\* Background (blog: Anthropic "Multi-Agent Coordination Patterns",
\* Agent Teams + Shared State): when one agent terminates while
\* holding work claimed from a shared queue, the queue must release
\* or reassign the work — otherwise the system loses progress
\* observability and subsequent consumers cannot tell whether a
\* claimed task is making progress or is orphaned.
\*
\* masc-mcp reference:
\*   lib/keeper/keeper_state_machine.ml (11-phase keeper FSM)
\*   lib/types/types_core.ml:254-268    (5-state task FSM:
\*     Todo | Claimed{assignee} | InProgress{assignee} |
\*     Done{assignee} | Cancelled{cancelled_by})
\*
\* A keeper going [Dead] while some task has [claimer = k] must not
\* leave that task in Claimed / InProgress. Either the task is
\* Released (back to Todo) or Cancelled as part of the Dead
\* transition.
\*
\* ── Abstraction note ──
\* The real keeper FSM has 11 phases; for this bug model we use
\* three abstract phases:
\*   Running       — representative of any dispatchable phase
\*                   (Running, Paused-and-resumable).
\*   Dead          — terminal tombstone (Dead, Crashed).
\*   Draining      — transient phase in which a clean shutdown
\*                   cascade fires: any claimed task owned by this
\*                   keeper must be released before entering Dead.
\* The collapse is sound for the NoDeadKeeperHoldsTask invariant
\* because the real FSM's Failing/Compacting/HandingOff/etc.
\* phases never transition directly to Dead without traversing the
\* drain path modelled here.

CONSTANTS K, T   \* sets of keeper names and task IDs

VARIABLES
    keeper_phase,    \* [K -> {"running","draining","dead"}]
    task_status,     \* [T -> {"todo","claimed","in_progress","done","cancelled"}]
    task_claimer     \* [T -> K \cup {"none"}]

vars == <<keeper_phase, task_status, task_claimer>>

Phases == {"running", "draining", "dead"}
\* "cancelled" is in Statuses for TypeOK completeness (the real task
\* FSM has Cancelled) but this model has no action that transitions
\* a task to "cancelled" — it is unreachable from Init. That is OK:
\* the NoDeadKeeperHoldsTask invariant is insensitive to Cancelled
\* since ~Held("cancelled"), and adding a CancelTask action would
\* only enlarge the state space without strengthening the invariant.
Statuses == {"todo", "claimed", "in_progress", "done", "cancelled"}
Claimers == K \cup {"none"}

Held(t) == task_status[t] \in {"claimed", "in_progress"}

TypeOK ==
    /\ keeper_phase \in [K -> Phases]
    /\ task_status  \in [T -> Statuses]
    /\ task_claimer \in [T -> Claimers]
    /\ \A t \in T : Held(t) => task_claimer[t] \in K
    /\ \A t \in T : (~Held(t)) => task_claimer[t] = "none"

Init ==
    /\ keeper_phase = [k \in K |-> "running"]
    /\ task_status  = [t \in T |-> "todo"]
    /\ task_claimer = [t \in T |-> "none"]

\* ── Task transitions ──────────────────────────────────

ClaimTask(t, k) ==
    /\ task_status[t] = "todo"
    /\ keeper_phase[k] = "running"
    /\ task_status'  = [task_status  EXCEPT ![t] = "claimed"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = k]
    /\ UNCHANGED keeper_phase

StartTask(t) ==
    /\ task_status[t] = "claimed"
    /\ LET k == task_claimer[t] IN
       /\ keeper_phase[k] = "running"
       /\ task_status'  = [task_status  EXCEPT ![t] = "in_progress"]
       /\ UNCHANGED <<keeper_phase, task_claimer>>

DoneTask(t) ==
    /\ task_status[t] = "in_progress"
    /\ task_status'  = [task_status  EXCEPT ![t] = "done"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

ReleaseTask(t) ==
    /\ task_status[t] \in {"claimed", "in_progress"}
    /\ task_status'  = [task_status  EXCEPT ![t] = "todo"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

\* ── Keeper lifecycle (clean path) ──────────────────────

\* Drain: a keeper transitions Running -> Draining voluntarily
\* (restart request, stop request, context exhaustion).
StartDrain(k) ==
    /\ keeper_phase[k] = "running"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "draining"]
    /\ UNCHANGED <<task_status, task_claimer>>

\* While draining, the keeper must release every task it still
\* holds before it can go to Dead.
DrainRelease(k, t) ==
    /\ keeper_phase[k] = "draining"
    /\ task_claimer[t] = k
    /\ Held(t)
    /\ task_status'  = [task_status  EXCEPT ![t] = "todo"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

\* Clean Dead transition: only allowed once the keeper holds no
\* tasks. The conjunction "no held task owned by k" is the drain
\* check the real code must enforce.
FinishDrain(k) ==
    /\ keeper_phase[k] = "draining"
    /\ \A t \in T : ~(task_claimer[t] = k /\ Held(t))
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "dead"]
    /\ UNCHANGED <<task_status, task_claimer>>

\* ── Clean Next ────────────────────────────────────────

Next ==
    \/ \E t \in T, k \in K : ClaimTask(t, k)
    \/ \E t \in T : StartTask(t)
    \/ \E t \in T : DoneTask(t)
    \/ \E t \in T : ReleaseTask(t)
    \/ \E k \in K : StartDrain(k)
    \/ \E k \in K, t \in T : DrainRelease(k, t)
    \/ \E k \in K : FinishDrain(k)

Spec == Init /\ [][Next]_vars

\* ── Safety Invariants ─────────────────────────────────

\* Core invariant: no Dead keeper holds a task.
NoDeadKeeperHoldsTask ==
    \A t \in T :
        Held(t) => keeper_phase[task_claimer[t]] /= "dead"

\* A task whose claimer is Draining is tolerated (the drain path
\* is mid-flight) but a Dead claimer is a bug.
ClaimerNotDead ==
    \A t \in T :
        task_claimer[t] \in K =>
            keeper_phase[task_claimer[t]] /= "dead"

\* ── Bug Model: skip-drain Dead transition ─────────────
\* Bug: a keeper crashes (Running -> Dead) without going through
\* the drain path — any tasks it was holding are now orphaned.
\* This is the exact regression the invariant should catch.

CrashToDead(k) ==
    /\ keeper_phase[k] = "running"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "dead"]
    /\ UNCHANGED <<task_status, task_claimer>>

\* Also model a bug in the drain cascade: FinishDrain forgets the
\* held-task check and goes to Dead regardless.
SloppyFinishDrain(k) ==
    /\ keeper_phase[k] = "draining"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "dead"]
    /\ UNCHANGED <<task_status, task_claimer>>

NextBuggy ==
    \/ Next
    \/ \E k \in K : CrashToDead(k)
    \/ \E k \in K : SloppyFinishDrain(k)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
