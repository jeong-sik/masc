---- MODULE ContractClosure ----
\* Contract-closure spec: autoresearch loop <-> verification <-> keeper FSM.
\*
\* Runtime truth being modelled:
\*   - An autoresearch loop for a task produces either Keep or Discard
\*     (after some number of cycles).
\*   - The task's verification gate is supposed to observe the
\*     autoresearch outcome and produce a Pass | Fail | Partial verdict
\*     for the task that owns the loop (task.contract.links.autoresearch_loop_id).
\*   - A Pass verdict should, under fairness, eventually unblock the
\*     keeper into its Running phase for that task.
\*
\* What this spec is FOR:
\*   - To enforce, as an invariant, that whenever an autoresearch loop
\*     has settled (Keep or Discard) for a task, that task's verification
\*     gate is no longer Pending (closure integrity).
\*   - To enforce, as a liveness property, that a Pass verdict eventually
\*     moves the keeper to Running for the owning task (weak fairness on
\*     the FSM transition).
\*
\* This is Layer 3 of the attribution rollout (see
\* planning/claude-plans/abundant-skipping-sutton.md).
\*
\* The *BUGGY* configuration (`ContractClosure-buggy.cfg`) enables an
\* AutoresearchOrphan action that settles the loop but omits the
\* verification update.  Under that action, ClosureIntegrity MUST be
\* violated — that is the current live-code gap (no bridge module).
\* This is the TLA+ form of the Bug Model pattern
\* (software-development.md).

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Tasks,             \* Finite set of task ids (small, e.g. {"t1","t2"})
    MaxCycles          \* Upper bound on autoresearch cycles per loop

ASSUME TasksNonEmpty == Tasks # {}
ASSUME MaxCyclesPos == MaxCycles \in Nat /\ MaxCycles >= 1

(* ── State values ───────────────────────────────────────── *)

\* Autoresearch outcome for the task's loop.
ArStates == {"ar_pending", "ar_keep", "ar_discard"}

\* Verification verdict for the task.
VrStates == {"vr_pending", "vr_pass", "vr_fail", "vr_partial"}

\* Keeper FSM phase, abstracted to just the two values we care about:
\* "fsm_idle" covers any non-Running phase.
FsmStates == {"fsm_idle", "fsm_running"}

VARIABLES
    ar,       \* [Tasks -> ArStates]
    ar_cycle, \* [Tasks -> 0..MaxCycles]  number of autoresearch cycles used
    vr,       \* [Tasks -> VrStates]
    fsm       \* [Tasks -> FsmStates]

vars == << ar, ar_cycle, vr, fsm >>

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ ar      \in [Tasks -> ArStates]
    /\ ar_cycle \in [Tasks -> 0..MaxCycles]
    /\ vr      \in [Tasks -> VrStates]
    /\ fsm     \in [Tasks -> FsmStates]

(* ── Initial state ──────────────────────────────────────── *)

Init ==
    /\ ar      = [ t \in Tasks |-> "ar_pending" ]
    /\ ar_cycle = [ t \in Tasks |-> 0 ]
    /\ vr      = [ t \in Tasks |-> "vr_pending" ]
    /\ fsm     = [ t \in Tasks |-> "fsm_idle" ]

(* ── Actions ────────────────────────────────────────────── *)

\* Run an autoresearch cycle for task t, if pending and budget remains.
\* This is the "work" step — doesn't settle the outcome.
ArTick(t) ==
    /\ ar[t] = "ar_pending"
    /\ ar_cycle[t] < MaxCycles
    /\ ar_cycle' = [ ar_cycle EXCEPT ![t] = ar_cycle[t] + 1 ]
    /\ UNCHANGED << ar, vr, fsm >>

\* The autoresearch loop settles into Keep, *and* the bridge module
\* propagates a verdict to verification. This is the CORRECT behaviour
\* — verification status is updated atomically with the autoresearch
\* settlement, matching the proposed autoresearch_result_bridge.ml.
ArSettleKeep(t) ==
    /\ ar[t] = "ar_pending"
    /\ ar_cycle[t] >= 1
    /\ ar' = [ ar EXCEPT ![t] = "ar_keep" ]
    /\ vr' = [ vr EXCEPT ![t] = "vr_pass" ]
    /\ UNCHANGED << ar_cycle, fsm >>

ArSettleDiscard(t) ==
    /\ ar[t] = "ar_pending"
    /\ ar_cycle[t] >= 1
    /\ ar' = [ ar EXCEPT ![t] = "ar_discard" ]
    /\ vr' = [ vr EXCEPT ![t] = "vr_fail" ]
    /\ UNCHANGED << ar_cycle, fsm >>

ArSettlePartial(t) ==
    /\ ar[t] = "ar_pending"
    /\ ar_cycle[t] >= 1
    /\ ar' = [ ar EXCEPT ![t] = "ar_keep" ]
    /\ vr' = [ vr EXCEPT ![t] = "vr_partial" ]
    /\ UNCHANGED << ar_cycle, fsm >>

\* Keeper FSM transition: a Pass verdict unblocks Running.
FsmToRunning(t) ==
    /\ vr[t] = "vr_pass"
    /\ fsm[t] = "fsm_idle"
    /\ fsm' = [ fsm EXCEPT ![t] = "fsm_running" ]
    /\ UNCHANGED << ar, ar_cycle, vr >>

(* ── Bug action (enabled only in the buggy twin) ────────── *)

\* The current live code: autoresearch writes its result into
\* .masc/autoresearch/{loop_id}/results.jsonl but NOTHING feeds it into
\* the verification gate — that wire doesn't exist.  Model that by
\* settling [ar] without touching [vr].
AutoresearchOrphan(t) ==
    /\ ar[t] = "ar_pending"
    /\ ar_cycle[t] >= 1
    /\ ar' = [ ar EXCEPT ![t] = "ar_keep" ]
    /\ UNCHANGED << ar_cycle, vr, fsm >>

(* ── Next-state relation ────────────────────────────────── *)

\* Clean (target) next-state: autoresearch settlement always carries
\* the verdict over to verification.
Next ==
    \E t \in Tasks :
        \/ ArTick(t)
        \/ ArSettleKeep(t)
        \/ ArSettleDiscard(t)
        \/ ArSettlePartial(t)
        \/ FsmToRunning(t)

\* Buggy next-state: add the orphan settlement path.  This should
\* violate ClosureIntegrity.
NextBuggy ==
    Next \/ (\E t \in Tasks : AutoresearchOrphan(t))

(* ── Safety: closure integrity ──────────────────────────── *)

\* Once autoresearch has settled (Keep or Discard), the verification
\* verdict for the owning task MUST have left "pending".  If this
\* invariant is violated, the dashboard sees an autoresearch outcome
\* with no matching verdict — which is exactly the current gap.
ClosureIntegrity ==
    \A t \in Tasks :
        (ar[t] \in {"ar_keep", "ar_discard"}) =>
            (vr[t] \in {"vr_pass", "vr_fail", "vr_partial"})

(* ── Liveness (Pass => eventually Running) ─────────────── *)

\* If a task ever becomes Pass-verified, under weak fairness on
\* FsmToRunning it eventually reaches Running.
VerdictUnblocksFsm ==
    \A t \in Tasks :
        [](vr[t] = "vr_pass" => <>(fsm[t] = "fsm_running"))

(* ── Specs ──────────────────────────────────────────────── *)

\* Fairness: every enabled action eventually runs (so Tick/Settle
\* and FsmToRunning all make progress).
Fairness ==
    /\ \A t \in Tasks : WF_vars(ArTick(t))
    /\ \A t \in Tasks : WF_vars(ArSettleKeep(t))
    /\ \A t \in Tasks : WF_vars(ArSettleDiscard(t))
    /\ \A t \in Tasks : WF_vars(ArSettlePartial(t))
    /\ \A t \in Tasks : WF_vars(FsmToRunning(t))

\* Clean spec. Safety + liveness should both hold.
Spec == Init /\ [][Next]_vars /\ Fairness

\* Buggy spec. Safety property ClosureIntegrity should be violated
\* in finite steps (no fairness required to demonstrate a safety
\* counterexample).
SpecBuggy == Init /\ [][NextBuggy]_vars

================================================================
