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
\*
\* ── Current implementation note (as of 2026-04-12) ──
\* The real code does NOT satisfy NoDeadKeeperHoldsTask
\* synchronously. Audited in issue #6609. Key findings:
\*
\*   1. Keeper_registry.mark_dead (keeper_registry.ml:237) sets
\*      entry.phase = Dead but never touches the task FSM. No
\*      task cascade fires on this call.
\*   2. cleanup_dead_tombstone (keeper_supervisor.ml:225) writes
\*      paused=true and unregisters the keeper; task FSM untouched.
\*   3. Task assignee = keeper's agent identity (the keeper IS the
\*      claimant), so a dead keeper's Claimed/InProgress tasks have
\*      task_claimer == keeper_name, and the TLA+ "Held ∧ Dead"
\*      predicate is directly reachable in practice.
\*
\* What actually restores the invariant:
\*
\*   Room_gc.cleanup_zombies (room/room_gc.ml:39-150) scans the
\*   agents directory on a periodic GC cycle, detects agents whose
\*   last_seen is older than Env_config.Zombie.keeper_threshold_seconds
\*   ("zombie" agents), and in Phase 3 iterates the backlog calling
\*   Room_hooks.force_release_task_fn for every Claimed/InProgress
\*   task whose assignee is a zombie. This is the **asynchronous,
\*   heartbeat-timeout-driven** path that eventually restores the
\*   NoDeadKeeperHoldsTask property.
\*
\* Implication for this spec:
\*
\*   This file formalizes an UPGRADE TARGET, not a proof of current
\*   correctness. A synchronous cascade from mark_dead into the task
\*   FSM would be the code change that makes the invariant hold
\*   without the GC window. Until that cascade exists, a Dead keeper
\*   can hold a Claimed task for up to ~keeper_threshold_seconds —
\*   the transient window is visible on the dashboard Keepers section
\*   (#6556) and is safe because Room.claim_task_r rejects any
\*   attempt by another agent to re-claim the orphaned task
\*   (TaskAlreadyClaimed), so no state corruption is possible.
\*
\* Do NOT read this file as "the code is broken". Read it as "here
\* is the discipline the code should enforce, and here is TLC ready
\* to catch a regression if someone tries to take a shortcut."
\*
\* Audit trichotomy reference: feedback memory
\*   feedback_tla-spec-audit-outcome-trichotomy.md
\* describes the three audit outcomes observed in the series:
\*   (1) safe by emission discipline (KeepalivePhaseConsistency)
\*   (2) safe by async independent path (this spec)
\*   (3) actual gap (none observed)

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

\* ── Current implementation model ──────────────────────
\* The real code (as of 2026-04-12) does not match the "clean drain"
\* discipline above. Instead, the real path is:
\*
\*   1. CrashToDead is a NORMAL lifecycle transition (restart budget
\*      exhausted, supervisor shutdown, crash recovery). It does NOT
\*      synchronously release claimed tasks — the post-crash registry
\*      update in keeper_registry.mark_dead leaves task_claimer
\*      pointing at the dead keeper.
\*
\*   2. A separate asynchronous subsystem, Room_gc.cleanup_zombies
\*      (lib/room/room_gc.ml), periodically scans agents by heartbeat
\*      last_seen and force-releases Claimed/InProgress tasks whose
\*      assignee is a zombie agent. This is modelled below as
\*      ReconcileByGC.
\*
\* So the current implementation satisfies the invariant
\* NoDeadKeeperHoldsTask only eventually, not synchronously. This
\* section models that reality and proves the eventual property with
\* a TLA+ fairness + leads-to (~>) construction, so TLC can verify
\* it against the TLC runner in tla-check.sh / specs/Makefile.

\* Zombie GC reconciliation: release an orphaned task whose claimer
\* is dead. Mirrors room_gc.ml:118-132 Phase 3 cascade.
ReconcileByGC(t) ==
    /\ Held(t)
    /\ keeper_phase[task_claimer[t]] = "dead"
    /\ task_status'  = [task_status  EXCEPT ![t] = "todo"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

\* The current path: CrashToDead is legitimate, ReconcileByGC is
\* the cleanup. We intentionally drop the clean Draining path
\* from NextCurrent because the current code does not use it for
\* mark_dead (it only runs during voluntary Operator_stop, which
\* is out of scope for this invariant).
NextCurrent ==
    \/ \E t \in T, k \in K : ClaimTask(t, k)
    \/ \E t \in T : StartTask(t)
    \/ \E t \in T : DoneTask(t)
    \/ \E t \in T : ReleaseTask(t)
    \/ \E k \in K : CrashToDead(k)
    \/ \E t \in T : ReconcileByGC(t)

\* Weak fairness on GC: if ReconcileByGC is continuously enabled
\* for some task, it must eventually fire. This is the formal
\* analogue of "the periodic GC cycle will eventually run and
\* cleanup_zombies will find this task".
SpecCurrent ==
    /\ Init
    /\ [][NextCurrent]_vars
    /\ WF_vars(\E t \in T : ReconcileByGC(t))

\* Predicate: there exists a task held by a dead keeper.
\* This is the safety violation we accept as a transient state
\* in the current implementation, bounded by GC cycle time.
OrphanedTaskExists ==
    \E t \in T : Held(t) /\ keeper_phase[task_claimer[t]] = "dead"

\* Liveness: once an orphaned state appears, it is eventually
\* resolved. This is the leads-to formalization of "async GC
\* eventually catches up".
EventuallyCleaned == OrphanedTaskExists ~> ~OrphanedTaskExists

\* Weaker safety suitable for the current model: any held task
\* that is not yet GC'd has a claimer that was *previously*
\* running. The claimer may currently be dead (awaiting GC), but
\* no task can have a claimer that was never running — that would
\* be a type error. TypeOK already guarantees this, so we keep it
\* as documentation: the only weaker-than-synchronous safety the
\* current model preserves is the stronger TypeOK guarantee.
====
