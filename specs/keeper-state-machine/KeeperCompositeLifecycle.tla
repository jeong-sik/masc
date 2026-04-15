---- MODULE KeeperCompositeLifecycle ----
\* Keeper Composite Lifecycle — Cross-spec Joint Invariants (Observer)
\*
\* Purpose
\*   The repository already has three partial composition specs:
\*     - KeeperCoreTriad.tla          State x Decision x Cascade (5-phase projection)
\*     - StateProduct.tla             Keeper x Turn x Validation
\*     - KeeperContextLifecycle.tla   Context + Compaction + Checkpoint + Recovery
\*   None of them check joint invariants that span all four domain FSMs
\*   (Decision, Cascade, MemoryCompaction, Compaction-phase) together, nor
\*   does any spec model the exact projected turn/decision/cascade state
\*   sequence now surfaced by the runtime observer.
\*
\*   This spec is an OBSERVER, not a new controller. It declares a minimum
\*   set of projected variables — each traceable to an OCaml module — and
\*   asserts joint invariants that no existing spec covers. It does not
\*   redefine the transitions of any sub-FSM; they are represented only at
\*   the resolution required for the joint properties.
\*
\*   Related audit: docs/tla-audit/state-fsm-gap-2026-04-13.md (proposals
\*   P1, P3, P4 — this spec absorbs P4 and encodes P3's clearing property).
\*
\* Runtime note (2026-04-16)
\*   The legacy manual_reconcile two-store runtime was retired in #7334.
\*   The live OCaml composite observer currently exports the recovery payload
\*   as a compatibility-clean projection (data_record=FALSE,
\*   fsm_condition=FALSE, recovery_two_store_sync=TRUE) so the dashboard/API
\*   wire contract remains total. The reconcile_data / reconcile_fsm clauses
\*   in this TLA+ module should therefore be read as historical audit model
\*   state, not current runtime-owned variables, until a new recovery
\*   contract is defined.
\*
\* Design intent
\*   1. shared_measurement is the coordination hub (Context_measured event,
\*      Keeper_state_machine.mli:131-136, auto_rules_summary).
\*   2. The 11-state parent phase from RFC-0002 is projected to
\*      {Running, Failing, Compacting, HandingOff, Draining, Stable}
\*      — exactly the phases that matter for cross-spec ordering.
\*   3. Parent-lifecycle recovery is modeled directly as Running/Failing
\*      phase transitions; legacy two-store manual_reconcile state is
\*      intentionally excluded from this observer.
\*   4. Model size kept small on purpose; TLC over this spec should
\*      complete in seconds, not hours.
\*
\* Non-goals (enforced structurally — see Boundary comment at end)
\*   - No transition of KSM/KTC/KDP/KMC/KCL is redefined here.
\*   - No provider/model identifier appears at any step.
\*   - No token counting happens in this spec (OAS owns budget math).

EXTENDS Naturals

CONSTANTS
    MaxTurnTicks       \* Small bound for model checking (e.g. 4)

ASSUME MaxTurnTicks \in Nat /\ MaxTurnTicks >= 2

\* ── Projected state variables ────────────────────────────
\* Each variable below is a PROJECTION of state owned by another spec or
\* OCaml module. The mapping is explicit and one-way; this spec never
\* writes back.

VARIABLES
    ksm_phase,          \* KSM projection. KeeperStateMachine.tla phase
                        \* Reduced to the 6 values that change cross-spec
                        \* behavior. Mapping from 11-state is in Comment A.

    ktc_turn_phase,     \* KTC projection. KeeperTurnCycle.tla / unified turn
                        \* Values: idle, prompting, executing, compacting,
                        \*         finalizing.

    kdp_decision,       \* KDP projection. KeeperDecisionPipeline.tla
                        \* Values: undecided, guard_ok, gate_rejected,
                        \*         tool_policy_selected.

    kcl_cascade_state,  \* KCL projection. CascadeLiveness.tla state set
                        \* Values: idle, selecting, trying, done, exhausted.

    kmc_compaction,     \* KMC projection. MemoryCompaction.tla phase
                        \* Values: accumulating, compacting, done.

    shared_measurement, \* Coordination hub. auto_rules_summary snapshot id
                        \* (Nat); 0 means "no measurement yet this turn".

    measurement_turn,   \* Turn tick at which current shared_measurement
                        \* was captured. Guards "measurement before cascade".

    turn_tick           \* Monotone counter used for ordering checks.

vars == <<ksm_phase, ktc_turn_phase, kdp_decision, kcl_cascade_state,
          kmc_compaction, shared_measurement, measurement_turn, turn_tick>>

\* ── Enumerated value sets ───────────────────────────────

\* Comment A — 12->7 phase projection (from RFC-0002 Transition Matrix):
\*   Running     -> Running
\*   Failing     -> Failing
\*   Overflowed  -> Overflowed     (added 2026-04, MASC-1)
\*   Compacting  -> Compacting
\*   HandingOff  -> HandingOff
\*   Draining    -> Draining
\*   Offline, Paused, Stopped, Crashed, Restarting, Dead -> Stable
\* This is a LOSSY projection; the joint invariants here hold for all
\* states that collapse to Stable by construction (they are outside the
\* turn cycle). Overflowed is tracked as its own phase because it couples
\* KSM with KMC (memory compaction) via the Start_compaction entry action.

PhaseSet       == {"Running", "Failing", "Overflowed", "Compacting",
                   "HandingOff", "Draining", "Stable"}
TurnPhaseSet   == {"idle", "prompting", "executing", "compacting",
                   "finalizing"}
DecisionSet    == {"undecided", "guard_ok", "gate_rejected",
                   "tool_policy_selected"}
CascadeSet     == {"idle", "selecting", "trying", "done", "exhausted"}
CompactionSet  == {"accumulating", "compacting", "done"}
ActionSet      == {
                   "StartTurn", "MeasurementBroadcast", "DecideGuard",
                   "SelectToolPolicy", "StartCascadeSelection",
                   "SelectCascade", "GateRejected", "CascadeDone",
                   "CascadeExhausted", "FinishTurn", "StartCompaction",
                   "FinishCompaction", "EnterFailing", "ClearFailing",
                   "EnterOverflowed", "OverflowedAutoCompact"
                  }
InvariantSet   == {
                   "PhaseTurnAlignment", "NoCascadeBeforeMeasurement",
                   "CompactionAtomicity", "EventPriorityMonotone"
                  }

TypeOK ==
    /\ ksm_phase \in PhaseSet
    /\ ktc_turn_phase \in TurnPhaseSet
    /\ kdp_decision \in DecisionSet
    /\ kcl_cascade_state \in CascadeSet
    /\ kmc_compaction \in CompactionSet
    /\ shared_measurement \in Nat
    /\ measurement_turn \in Nat
    /\ turn_tick \in 0..MaxTurnTicks

\* ── Initial state ────────────────────────────────────────

Init ==
    /\ ksm_phase = "Running"
    /\ ktc_turn_phase = "idle"
    /\ kdp_decision = "undecided"
    /\ kcl_cascade_state = "idle"
    /\ kmc_compaction = "accumulating"
    /\ shared_measurement = 0
    /\ measurement_turn = 0
    /\ turn_tick = 0

\* ── Domain actions (abstract) ────────────────────────────
\* Each action below is a narrow abstraction of a sub-FSM transition.
\* The sub-FSM's detailed behaviour is verified in its own spec; here
\* we only move enough state to observe cross-spec properties.

StartTurn ==
    /\ ksm_phase = "Running"
    /\ ktc_turn_phase = "idle"
    /\ turn_tick < MaxTurnTicks
    /\ ktc_turn_phase' = "prompting"
    /\ turn_tick' = turn_tick + 1
    /\ shared_measurement' = 0           \* reset hub at turn start
    /\ measurement_turn' = 0
    /\ kdp_decision' = "undecided"
    /\ kcl_cascade_state' = "idle"
    /\ kmc_compaction' =
         IF kmc_compaction = "done" THEN "accumulating" ELSE kmc_compaction
    /\ UNCHANGED <<ksm_phase>>

MeasurementBroadcast ==                  \* Context_measured (priority 5)
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement = 0            \* exactly once per turn (P3-like)
    /\ shared_measurement' = turn_tick    \* any unique, nonzero value
    /\ measurement_turn' = turn_tick
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, kmc_compaction, turn_tick>>

DecideGuard ==
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement /= 0
    /\ kdp_decision = "undecided"
    /\ kdp_decision' = "guard_ok"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick>>

SelectToolPolicy ==
    /\ ktc_turn_phase = "prompting"
    /\ kdp_decision = "guard_ok"
    /\ kdp_decision' = "tool_policy_selected"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick>>

StartCascadeSelection ==
    /\ ktc_turn_phase = "prompting"
    /\ kdp_decision = "tool_policy_selected"
    /\ shared_measurement /= 0
    /\ kcl_cascade_state = "idle"
    /\ kcl_cascade_state' = "selecting"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick>>

SelectCascade ==
    /\ kcl_cascade_state = "selecting"
    /\ shared_measurement /= 0
    /\ kcl_cascade_state' = "trying"
    /\ ktc_turn_phase' = "executing"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick>>

GateRejected ==
    /\ ktc_turn_phase \in {"prompting", "executing"}
    /\ kdp_decision \in {"guard_ok", "tool_policy_selected"}
    /\ kdp_decision' = "gate_rejected"
    /\ ktc_turn_phase' = "finalizing"
    /\ kcl_cascade_state' = "idle"
    /\ UNCHANGED <<ksm_phase, kmc_compaction, shared_measurement,
                   measurement_turn, turn_tick>>

CascadeDone ==
    /\ kcl_cascade_state = "trying"
    /\ kcl_cascade_state' = "done"
    /\ ktc_turn_phase' = "finalizing"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick>>

CascadeExhausted ==
    /\ kcl_cascade_state = "trying"
    /\ kcl_cascade_state' = "exhausted"
    /\ ktc_turn_phase' = "finalizing"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick>>

\* FinishTurn — closes the current turn and resets per-turn sub-FSM state.
\* Without this, the next StartTurn would keep kcl_cascade_state stale
\* while the measurement is re-cleared, violating NoCascadeBeforeMeasurement.
FinishTurn ==
    /\ ktc_turn_phase = "finalizing"
    /\ ktc_turn_phase' = "idle"
    /\ kcl_cascade_state' = "idle"
    /\ kdp_decision' = "undecided"
    /\ shared_measurement' = 0
    /\ measurement_turn' = 0
    /\ UNCHANGED <<ksm_phase, kmc_compaction, turn_tick>>

\* Compaction is coupled: parent phase + turn phase + memory phase
\* must co-advance (CompactionAtomicity).
StartCompaction ==
    /\ ksm_phase = "Running"
    /\ ktc_turn_phase \in {"idle", "finalizing"}
    /\ kmc_compaction = "accumulating"
    /\ ksm_phase' = "Compacting"
    /\ ktc_turn_phase' = "compacting"
    /\ kmc_compaction' = "compacting"
    /\ kcl_cascade_state' = "idle"
    /\ kdp_decision' = "undecided"
    /\ UNCHANGED <<shared_measurement, measurement_turn, turn_tick>>

FinishCompaction ==
    /\ ksm_phase = "Compacting"
    /\ kmc_compaction = "compacting"
    /\ ksm_phase' = "Running"
    /\ ktc_turn_phase' = "idle"
    /\ kmc_compaction' = "done"
    /\ UNCHANGED <<kdp_decision, kcl_cascade_state, shared_measurement,
                   measurement_turn, turn_tick>>

EnterFailing ==
    /\ ksm_phase = "Running"
    /\ ksm_phase' = "Failing"
    /\ UNCHANGED <<ktc_turn_phase, kdp_decision, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick>>

ClearFailing ==
    /\ ksm_phase = "Failing"
    /\ ksm_phase' = "Running"
    /\ UNCHANGED <<ktc_turn_phase, kdp_decision, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick>>

\* Overflowed orchestration (Context overflow detected).
\* Entry aborts the in-flight turn so the auto-compaction that follows
\* cannot race an active SelectCascade/Attempt (mirror of EnterFailing).
EnterOverflowed ==
    /\ ksm_phase = "Running"
    /\ ksm_phase' = "Overflowed"
    /\ ktc_turn_phase' = "idle"
    /\ kdp_decision' = "undecided"
    /\ kcl_cascade_state' = "idle"
    /\ shared_measurement' = 0
    /\ measurement_turn' = 0
    /\ UNCHANGED <<kmc_compaction, turn_tick>>

\* Overflowed -> Compacting (Start_compaction entry action).
\* Atomically moves KSM, KTC, KMC so CompactionAtomicity is preserved:
\* kmc_compaction="compacting" is never observed with ksm_phase="Overflowed"
\* at a reached state.
OverflowedAutoCompact ==
    /\ ksm_phase = "Overflowed"
    /\ ksm_phase' = "Compacting"
    /\ ktc_turn_phase' = "compacting"
    /\ kmc_compaction' = "compacting"
    /\ UNCHANGED <<kdp_decision, kcl_cascade_state, shared_measurement,
                   measurement_turn, turn_tick>>

\* ── Next-state relation ──────────────────────────────────

Next ==
    \/ StartTurn
    \/ MeasurementBroadcast
    \/ DecideGuard
    \/ SelectToolPolicy
    \/ StartCascadeSelection
    \/ SelectCascade
    \/ GateRejected
    \/ CascadeDone
    \/ CascadeExhausted
    \/ FinishTurn
    \/ StartCompaction
    \/ FinishCompaction
    \/ EnterFailing
    \/ ClearFailing
    \/ EnterOverflowed
    \/ OverflowedAutoCompact

Fairness ==
    /\ WF_vars(MeasurementBroadcast)
    /\ WF_vars(DecideGuard)
    /\ WF_vars(SelectToolPolicy)
    /\ WF_vars(StartCascadeSelection)
    /\ WF_vars(SelectCascade)
    /\ WF_vars(CascadeDone)
    /\ WF_vars(CascadeExhausted)
    /\ WF_vars(FinishTurn)
    /\ WF_vars(FinishCompaction)
    /\ WF_vars(ClearFailing)
    /\ WF_vars(OverflowedAutoCompact)

Spec == Init /\ [][Next]_vars /\ Fairness

\* ── Safety invariants (clean cfg must pass) ──────────────

\* I1 — PhaseTurnAlignment
\* When the parent phase is Compacting, the turn phase and memory phase
\* must also be in their compacting states. Encodes the post-turn
\* lifecycle atomicity in keeper_post_turn.ml:45-232.
PhaseTurnAlignment ==
    (ksm_phase = "Compacting") =>
        (ktc_turn_phase = "compacting" /\ kmc_compaction = "compacting")

\* I2 — NoCascadeBeforeMeasurement
\* Cascade selection cannot advance past idle/selecting without a
\* measurement having been taken in the current turn.
NoCascadeBeforeMeasurement ==
    (kcl_cascade_state \in {"selecting", "trying", "done", "exhausted"}) =>
        (shared_measurement /= 0 /\ measurement_turn = turn_tick)

\* I3 — CompactionAtomicity
\* Memory compaction progress and parent Compacting phase stay consistent:
\* KMC cannot be in "compacting" while the parent is Running.
CompactionAtomicity ==
    (kmc_compaction = "compacting") =>
        (ksm_phase = "Compacting")

\* I4 — EventPriorityMonotone
\* At most one measurement per turn (priority 5 cannot fire twice per
\* turn, keeper_guard.ml). Enforced by the guard in MeasurementBroadcast;
\* re-asserted as observable invariant for completeness.
EventPriorityMonotone ==
    (shared_measurement /= 0) => (measurement_turn <= turn_tick)

SafetyInvariant ==
    /\ TypeOK
    /\ PhaseTurnAlignment
    /\ NoCascadeBeforeMeasurement
    /\ CompactionAtomicity
    /\ EventPriorityMonotone

\* ── Liveness ─────────────────────────────────────────────

\* L1 — EventualMeasurementResolves
\* Every prompting turn eventually sees a measurement.
EventualMeasurementResolves ==
    (ktc_turn_phase = "prompting") ~>
        (shared_measurement /= 0 \/ ktc_turn_phase /= "prompting")

\* L2 — FailingEventuallyClears
\* A Failing episode must eventually return to Running.
RecoveryEventuallyCompletes ==
    (ksm_phase = "Failing") ~> (ksm_phase = "Running")

\* L3 — OverflowedEventuallyResolves
\* Overflowed must not be a terminal sink — it has to advance into Compacting
\* (auto-compaction entry action), or collapse into the Stable bucket on
\* operator action. Relies on WF_vars(OverflowedAutoCompact).
OverflowedEventuallyResolves ==
    (ksm_phase = "Overflowed") ~> (ksm_phase /= "Overflowed")

\* ── Bug models (each violates a distinct invariant) ──

\* NextBuggyCascade — enter cascade selection without measurement
\* Violates: NoCascadeBeforeMeasurement
BugCascadeBeforeMeasurement ==
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement = 0
    /\ kdp_decision = "undecided"
    /\ kcl_cascade_state = "idle"
    /\ kdp_decision' = "tool_policy_selected"
    /\ kcl_cascade_state' = "selecting"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick>>

NextBuggyCascade == Next \/ BugCascadeBeforeMeasurement

\* NextBuggyCompaction — KMC advances without KSM/KTC coupling
\* Violates: PhaseTurnAlignment and CompactionAtomicity
BugCompactionDesync ==
    /\ ksm_phase = "Running"
    /\ kmc_compaction = "accumulating"
    /\ kmc_compaction' = "compacting"     \* BUG: KSM and KTC stay put
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, shared_measurement, measurement_turn,
                   turn_tick>>

NextBuggyCompaction == Next \/ BugCompactionDesync

SpecBuggyCascade    == Init /\ [][NextBuggyCascade]_vars /\ Fairness
SpecBuggyCompaction == Init /\ [][NextBuggyCompaction]_vars /\ Fairness

\* ── Boundary comments (reviewer gate) ────────────────────
\* This spec must NOT introduce any of the following, per:
\*   memory/feedback_no-lifecycle-invasion-from-masc.md
\*   memory/feedback_masc-oas-layer-boundary.md
\*   memory/feedback_masc-model-agnostic.md
\*   memory/feedback_budget-belongs-in-oas.md
\* Forbidden in this file (reviewers: grep for these):
\*   - provider / model identifiers (groq, ollama, claude, ...)
\*   - token counts or context byte sizes
\*   - redefinition of transitions owned by sub-specs
\*   - MASC mutation of OAS-owned state

====
