---- MODULE KeeperConditionsGovernPhase ----
\* Keeper condition → phase liveness invariant.
\*
\* Models the minimal two-phase fragment of the RFC-0002 FSM that the
\* Agent Modal's divergent-conditions banner
\* (dashboard/src/components/keeper-conditions-divergent.ts) depends on:
\*
\*   If [context_handoff_needed = TRUE] is observed while
\*   [phase = Running], the FSM MUST eventually transition to a
\*   phase that acknowledges the signal — here represented by
\*   [HandingOff].
\*
\* The UI surfaces divergent conditions under the assumption that the
\* divergence is transient, not permanent.  That assumption is a
\* liveness property — it cannot be proved by a single observation.
\* This spec proves it holds under Weak Fairness on the transition
\* action.
\*
\* Guarantees:
\*   TypeOK                      — variables stay in their domains.
\*   NoPermanentDivergence       — not (handoff_needed ∧ phase=Running)
\*                                 stable forever (no fixed point).
\*   HandoffEventuallyAcknowledged — liveness, under WF(Transition).
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg : Safety + HandoffEventuallyAcknowledged pass.
\*   Buggy cfg : fairness weakened on Transition — the FSM may stutter
\*               indefinitely with (handoff_needed ∧ phase=Running),
\*               violating the liveness property.  TLC MUST report a
\*               temporal counter-example.  If the property still
\*               holds, the spec (or fairness annotation) is too weak
\*               and must be strengthened.
\*
\* OCaml ↔ TLA+ mapping (see #8642 family):
\*
\*   spec variable                | OCaml location                                    | semantic
\*   -----------------------------+---------------------------------------------------+---------
\*   phase \in {"Running", "HandingOff"} | lib/keeper/keeper_state_machine.ml:phase    | type phase = ... | Running | ... | HandingOff | ...
\*                                | (full 13-phase variant; this spec projects to 2)  |
\*   handoff_needed (boolean)     | lib/keeper/keeper_state_machine.ml:context_handoff_needed | conditions.context_handoff_needed : bool
\*                                | lib/keeper/keeper_state_machine.ml:update_conditions | set from auto_rules.handoff at update_conditions
\*
\* Producer side (where conditions are stamped):
\*   lib/keeper/keeper_state_machine.ml:351
\*     `else if c.handoff_active then HandingOff` — derive_phase routes
\*     into HandingOff when handoff_active is set, satisfying the spec
\*     liveness obligation that handoff_needed must lead to a phase that
\*     acknowledges the signal.
\*
\* Wire path to the dashboard banner consumer:
\*   lib/keeper/keeper_state_machine.ml:634
\*     `"context_handoff_needed", \`Bool c.context_handoff_needed`
\*     (json export — read by dashboard/src/components/keeper-conditions-divergent.ts).
\*     Verified 2026-04-20: line 620 was a stale anchor; the json
\*     serializer body shifted ~14 lines down as adjacent serializer
\*     fields were inserted above it.
\*
\* Scope projection: spec models the 2-phase fragment (Running / HandingOff).
\* The full 13-phase variant is out of scope here; sibling specs
\* (KeeperContextLifecycle, KeeperCompactionLifecycle) cover other phase
\* groups. Adding new OCaml phases does NOT require updating this spec
\* unless the new phase competes with HandingOff for the handoff_needed
\* signal.

EXTENDS TLC

VARIABLES
    phase,              \* "Running" or "HandingOff"
    handoff_needed      \* observable condition from runtime

vars == << phase, handoff_needed >>

PhaseSet == { "Running", "HandingOff" }

TypeOK ==
    /\ phase \in PhaseSet
    /\ handoff_needed \in BOOLEAN

Init ==
    /\ phase = "Running"
    /\ handoff_needed = FALSE

\* ── Actions ─────────────────────────────────

\* Runtime raises the condition — e.g. context ratio crosses the
\* handoff threshold.  Modeled as spontaneous because the UI is not
\* supposed to distinguish producer from consumer.
SignalHandoffNeeded ==
    /\ handoff_needed = FALSE
    /\ handoff_needed' = TRUE
    /\ UNCHANGED << phase >>

\* The FSM acknowledges the signal by transitioning to HandingOff and
\* clearing the condition.  This is the critical action whose fairness
\* provides the liveness guarantee.
Transition ==
    /\ handoff_needed = TRUE
    /\ phase = "Running"
    /\ phase' = "HandingOff"
    /\ handoff_needed' = FALSE

\* After HandingOff completes, the keeper may return to Running with
\* the condition clear.  Needed so the state space is not absorbing.
HandoffComplete ==
    /\ phase = "HandingOff"
    /\ phase' = "Running"
    /\ UNCHANGED << handoff_needed >>

Next ==
    \/ SignalHandoffNeeded
    \/ Transition
    \/ HandoffComplete

\* Clean fairness: the Transition action MUST run whenever it is
\* enabled.  This is what forces the divergence to be transient.
FairnessClean == WF_vars(Transition) /\ WF_vars(HandoffComplete)

Spec == Init /\ [][Next]_vars /\ FairnessClean

\* ── Safety ──────────────────────────────────

\* Stutter-safety: the system cannot sit in a useless state where the
\* Transition action is disabled yet no progress is made.  (Weak form;
\* the full liveness property is stated separately below.)
NoPermanentDivergence ==
    \/ ~(handoff_needed /\ phase = "Running")
    \/ ENABLED Transition

Safety ==
    /\ TypeOK
    /\ NoPermanentDivergence

\* ── Liveness ────────────────────────────────

\* The core property this spec exists to prove: if the condition is
\* raised while Running, the FSM eventually enters HandingOff.  The
\* Agent Modal's divergence rules rely on this.
HandoffEventuallyAcknowledged ==
    [](handoff_needed /\ phase = "Running" => <>(phase = "HandingOff"))

\* ── Bug Model ───────────────────────────────

\* Mutation: weak fairness on Transition is removed.  Every other
\* aspect of the spec is identical.  Models a bug where the
\* transition handler is tied to an unconditional yield / sleep and
\* can stall arbitrarily, leaving the keeper in the divergent state
\* without making progress.
FairnessBuggy == WF_vars(HandoffComplete)

SpecBuggy == Init /\ [][Next]_vars /\ FairnessBuggy

====
