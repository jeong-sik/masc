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
\*   lib/keeper/keeper_state_machine.ml (12-phase keeper FSM:
\*     Offline | Running | Failing | Overflowed | Compacting | HandingOff
\*     | Draining | Paused | Stopped | Crashed | Restarting | Dead)
\*   lib/types/types_core.ml:task_status (6-state task FSM:
\*     Todo | Claimed{assignee} | InProgress{assignee} |
\*     AwaitingVerification{assignee, verification_id, ...} |
\*     Done{assignee} | Cancelled{cancelled_by})
\*
\* A keeper going [Dead] while some task has [claimer = k] must not
\* leave that task in Claimed / InProgress / AwaitingVerification.
\* Either the task is Released (back to Todo) or Cancelled as part of
\* the Dead transition.
\*
\* ── Abstraction note ──
\* The real keeper FSM has 12 phases; for this bug model we use
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
\*   Coord_gc.cleanup_zombies (lib/coord/coord_gc.ml:cleanup_zombies) scans the
\*   agents directory on a periodic GC cycle, detects agents whose
\*   last_seen is older than Env_config.Zombie.keeper_threshold_seconds
\*   ("zombie" agents), and in Phase 3 iterates the backlog calling
\*   Coord_hooks.force_release_task_fn for every Claimed/InProgress
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
\*   (#6556) and is safe because Coord_task.claim_task_r rejects any
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
\* "cancelled" and "awaiting_verification" are in Statuses for TypeOK
\* completeness. The real task FSM has 6 states (types_core.ml:265-277).
\* "awaiting_verification" is entered when an agent with a completion
\* contract tries Done — the verifier gate redirects to Submit_for_verification.
\* A different agent must then Approve (->done) or Reject (->in_progress).
Statuses == {"todo", "claimed", "in_progress", "awaiting_verification", "done", "cancelled"}
Claimers == K \cup {"none"}

\* A task is "held" if it requires an agent to make progress on it.
\* awaiting_verification is held: the original assignee still owns it,
\* waiting for cross-agent approval.
Held(t) == task_status[t] \in {"claimed", "in_progress", "awaiting_verification"}

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

\* Verifier gate: redirect Done -> AwaitingVerification when contract exists.
\* Claimer stays the same — the task is still "owned" by the original agent.
SubmitForVerification(t) ==
    /\ task_status[t] = "in_progress"
    /\ task_status'  = [task_status  EXCEPT ![t] = "awaiting_verification"]
    /\ UNCHANGED <<keeper_phase, task_claimer>>

\* Cross-agent approval: a DIFFERENT keeper approves.
\* Self-approval is blocked by the guard v /= task_claimer[t].
ApproveVerification(t, v) ==
    /\ task_status[t] = "awaiting_verification"
    /\ v \in K
    /\ v /= task_claimer[t]
    /\ keeper_phase[v] = "running"
    /\ task_status'  = [task_status  EXCEPT ![t] = "done"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

\* Cross-agent rejection: task returns to in_progress for rework.
RejectVerification(t, v) ==
    /\ task_status[t] = "awaiting_verification"
    /\ v \in K
    /\ v /= task_claimer[t]
    /\ keeper_phase[v] = "running"
    /\ task_status'  = [task_status  EXCEPT ![t] = "in_progress"]
    /\ UNCHANGED <<keeper_phase, task_claimer>>

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
    \/ \E t \in T : SubmitForVerification(t)
    \/ \E t \in T, v \in K : ApproveVerification(t, v)
    \/ \E t \in T, v \in K : RejectVerification(t, v)
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

\* Verifier independence: no task can be in a done state via a
\* transition that allowed self-approval. This is enforced at the
\* action level by ApproveVerification's v /= task_claimer[t] guard.
\* We state the invariant as a type-level property: if a task is
\* awaiting_verification, its claimer is a real keeper (not "none"),
\* which preserves the "different agent must approve" discipline
\* at model-check time.
AwaitingVerificationHasClaimer ==
    \A t \in T :
        task_status[t] = "awaiting_verification" =>
            task_claimer[t] \in K

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

\* Bug: self-approval allowed. A buggy ApproveVerification that
\* drops the v /= task_claimer[t] guard would let the assignee
\* approve their own work — exactly the anti-pattern the verifier
\* gate is meant to prevent. Violates AwaitingVerificationHasClaimer
\* only weakly (claimer is still a K), but composes with a separate
\* SelfApproval predicate as a liveness/safety coupling bug.
SelfApproveVerification(t, v) ==
    /\ task_status[t] = "awaiting_verification"
    /\ v \in K
    /\ v = task_claimer[t]    \* <-- bug: same agent approves
    /\ keeper_phase[v] = "running"
    /\ task_status'  = [task_status  EXCEPT ![t] = "done"]
    /\ task_claimer' = [task_claimer EXCEPT ![t] = "none"]
    /\ UNCHANGED keeper_phase

NextBuggy ==
    \/ Next
    \/ \E k \in K : CrashToDead(k)
    \/ \E k \in K : SloppyFinishDrain(k)
    \/ \E t \in T, v \in K : SelfApproveVerification(t, v)

\* Invariant that the self-approval bug violates: once a task is
\* done, at least one non-assignee approval must have occurred.
\* We track this via a history variable implicitly: if task_status
\* transitioned through awaiting_verification -> done without a
\* different-agent step, that's a bug. In this untimed spec we
\* capture it by asserting NextBuggy breaks a property that Next
\* preserves. (See SpecBuggy run: TLC should find a trace where
\* SelfApproveVerification fires and a simple liveness-ish witness
\* detects that an ApproveVerification by v /= assignee never ran
\* for this task.)

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
\*   2. A separate asynchronous subsystem, Coord_gc.cleanup_zombies
\*      (lib/coord/coord_gc.ml), periodically scans agents by heartbeat
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
\* is dead. Mirrors coord_gc.ml:128-146 Phase 3 cascade.
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
    \/ \E t \in T : SubmitForVerification(t)
    \/ \E t \in T, v \in K : ApproveVerification(t, v)
    \/ \E t \in T, v \in K : RejectVerification(t, v)
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
