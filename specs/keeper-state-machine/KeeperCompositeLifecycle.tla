---- MODULE KeeperCompositeLifecycle ----
\* Keeper Composite Lifecycle — Cross-spec Joint Invariants (Observer)
\*
\* Purpose
\*   The repository already has three partial composition specs:
\*     - KeeperCoreTriad.tla          State x Decision x Cascade (7-phase projection)
\*     - StateProduct.tla             Keeper x Turn x Validation
\*     - KeeperContextLifecycle.tla   Context + Compaction + Checkpoint + Recovery
\*   None of them check joint invariants that span all four domain FSMs
\*   (Decision, CascadeLifecycle, CompactionLifecycle, parent phase) together, nor
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
\* Design intent
\*   1. shared_measurement is the coordination hub (Context_measured event,
\*      Keeper_state_machine.mli -- [Context_measured] constructor of
\*      [type event], auto_rules_summary). Cite by symbol -- iter 64 N-2.a
\*      (line numbers drift on every edit; [type event] / [Context_measured]
\*      are stable identifiers, the OCaml compiler keeps them honest).
\*      Adjacent NoDrainTransition / GhostDispatch *.mli docstring callouts
\*      are anchored similarly by name, not by line number.
\*   2. The 13-state parent phase from RFC-0002 is projected to the
\*      7-element set
\*      {Running, Failing, Overflowed, Compacting, HandingOff, Draining,
\*       Stable}
\*      — exactly the phases that matter for cross-spec ordering.
\*      (See Comment A for the explicit 13->7 mapping; the 7 phases that
\*      collapse to "Stable" are out of scope for the joint invariants
\*      because they sit outside the turn cycle.)
\*   3. Parent-lifecycle recovery is modeled directly as Running/Failing
\*      phase transitions; legacy two-store recovery placeholders are
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
                        \* Reduced to the 7 values that change cross-spec
                        \* behavior (6 active + Stable absorber).
                        \* Mapping from 12-state OCaml phase is in Comment A.

    ktc_turn_phase,     \* KTC projection. KeeperTurnCycle.tla / unified turn
                        \* Values: idle, prompting, executing, compacting,
                        \*         finalizing.

    kdp_decision,       \* KDP projection. KeeperDecisionPipeline.tla
                        \* Values: undecided, guard_ok, gate_rejected,
                        \*         tool_policy_selected.

    kcl_cascade_state,  \* KCL projection. keeper-facing cascade lifecycle
                        \* Values: idle, selecting, trying, done, exhausted.

    kmc_compaction,     \* KMC projection. keeper-facing compaction lifecycle
                        \* Values: accumulating, compacting, done.

    shared_measurement, \* Coordination hub. auto_rules_summary snapshot id
                        \* (Nat); 0 means "no measurement yet this turn".

    measurement_turn,   \* Turn tick at which current shared_measurement
                        \* was captured. Guards "measurement before cascade".

    turn_tick,          \* Monotone counter used for ordering checks.

    \* ── RFC-0065 Phase 5.1.b projections ────────────────────
    \* Three new sub-FSM projections coupled into this observer per
    \* RFC-0065 §3.4.  Each is the smallest abstraction sufficient
    \* for one joint invariant; the detailed transitions belong to
    \* their owning specs (KeeperCascadeAttemptFSM, KeeperToolSurface,
    \* KeeperPostTurnOrchestration).

    kcaf_attempt_phase, \* B1 (KeeperCascadeAttemptFSM) projection.
                        \* Values: "idle", "attempting", "terminal".
                        \* Source spec: KeeperCascadeAttemptFSM.tla — its
                        \* full 6-phase enum (idle/attempting/awaiting_
                        \* response/success/exhausted_normal/exhausted_
                        \* hard_quota) collapses to 3 here.

    kts_surface_ready,  \* B2 (KeeperToolSurface) projection.
                        \* BOOLEAN — TRUE iff the tool-surface pipeline
                        \* has produced a non-empty emitted set this
                        \* turn.  Mirrors KeeperToolSurface.tla phase =
                        \* "computed" with emitted /= {}.

    kpto_phase          \* B3 (KeeperPostTurnOrchestration) projection.
                        \* Values: "idle", "active", "persisted".
                        \* "active" covers the wirein A5→A6→K4b→K1 +
                        \* lineage append run; "persisted" covers
                        \* checkpoint persist.  Source spec:
                        \* KeeperPostTurnOrchestration.tla.

vars == <<ksm_phase, ktc_turn_phase, kdp_decision, kcl_cascade_state,
          kmc_compaction, shared_measurement, measurement_turn, turn_tick,
          kcaf_attempt_phase, kts_surface_ready, kpto_phase>>

\* ── Enumerated value sets ───────────────────────────────

\* Comment A — 13->7 phase projection (from RFC-0002 Transition Matrix
\* + Zombie extension added iter 4 #14707):
\*   Running     -> Running
\*   Failing     -> Failing
\*   Overflowed  -> Overflowed     (added 2026-04, MASC-1)
\*   Compacting  -> Compacting
\*   HandingOff  -> HandingOff
\*   Draining    -> Draining
\*   Offline, Paused, Stopped, Crashed, Restarting, Dead, Zombie -> Stable
\*                                                       (Zombie added iter 4
\*                                                        #14707 — terminal
\*                                                        post-Dead, outside
\*                                                        the turn cycle ⇒
\*                                                        structurally Stable)
\* This is a LOSSY projection; the joint invariants here hold for all
\* states that collapse to Stable by construction (they are outside the
\* turn cycle). Overflowed is tracked as its own phase because it couples
\* KSM with KMC (memory compaction) via the Start_compaction entry action.

PhaseSet       == {"Running", "Failing", "Overflowed", "Compacting",
                   "HandingOff", "Draining", "Stable"}

\* TurnPhaseSet: KTC projection.  iter 39 R-E-1.a (2026-05-12) sync —
\* KTC.tla:127 widened to 7 members in iter 28 (#14793 R-B-1.a) to match
\* OCaml's 7-constructor `Keeper_registry.turn_phase`; KCL had carried
\* the pre-iter-28 5-member set, creating a cross-spec drift documented
\* in `docs/tla-audit/kcl-e1-cross-spec-projection-drift-2026-05-12.md`
\* (PR #14822 Finding 1, HIGH risk).  Type widening only — KCL's existing
\* observer actions don't transition into routing/exhausted; per-attempt
\* FSM is owned by KCAF and the keeper-projection action set by KTC
\* (B-2 audit #14809).  Action modeling deferred — see KTC R-B-2.{a,b,c}.
TurnPhaseSet   == {"idle", "prompting", "routing", "executing",
                   "compacting", "finalizing", "exhausted"}

DecisionSet    == {"undecided", "guard_ok", "gate_rejected",
                   "tool_policy_selected"}
CascadeSet     == {"idle", "selecting", "trying", "done", "exhausted"}
CompactionSet  == {"accumulating", "compacting", "done"}

\* KcafPhaseSet: DELIBERATE 3:6 projection collapse from KCAF.tla:79-81.
\* iter 39 R-E-1.c (2026-05-12, this commit) documents the mapping per
\* iter 38 KCL E-1 Finding 2 (PR #14822):
\*
\*   KCL abstract      ↔  KCAF concrete
\*   "idle"            ↔  "idle"
\*   "attempting"      ↔  "attempting", "awaiting_response"
\*   "terminal"        ↔  "success", "exhausted_normal", "exhausted_hard_quota"
\*
\* The terminal collapse silently merges KCAF's distinguished terminals
\* (exhausted_normal vs exhausted_hard_quota documented in D-2 audit
\* #14815).  Joint invariants conditioning on `kcaf_attempt_phase` cannot
\* distinguish hard-quota from normal exhaustion at the cross-spec level
\* — the D-2 safety surface (HardQuotaTerminalImmediate +
\* BugHardQuotaBypass) lives only in KCAF, not in any KCL joint property.
\* This is INTENTIONAL: KCL operates at a coarser observation
\* granularity; per-terminal-flavor invariants belong in KCAF.
KcafPhaseSet   == {"idle", "attempting", "terminal"}

KptoPhaseSet   == {"idle", "active", "persisted"}
ActionSet      == {
                   "StartTurn", "MeasurementBroadcast", "DecideGuard",
                   "SelectToolPolicy", "ComputeToolSurface",
                   "StartCascadeSelection",
                   "SelectCascade", "GateRejected", "CascadeDone",
                   "CascadeExhausted", "FinishTurn", "StartCompaction",
                   "FinishCompaction", "EnterFailing", "ClearFailing",
                   "EnterOverflowed", "OverflowedAutoCompact",
                   "EnterPostTurn", "PersistCheckpoint"
                  }
InvariantSet   == {
                   "PhaseTurnAlignment", "NoCascadeBeforeMeasurement",
                   "CompactionAtomicity", "EventPriorityMonotone",
                   "AttemptFSMRespectsAdmission",
                   "ToolSurfaceFeedsAttempt",
                   "PostTurnConsumesAttempt"
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
    /\ kcaf_attempt_phase \in KcafPhaseSet
    /\ kts_surface_ready \in BOOLEAN
    /\ kpto_phase \in KptoPhaseSet

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
    /\ kcaf_attempt_phase = "idle"
    /\ kts_surface_ready = FALSE
    /\ kpto_phase = "idle"

\* ── Domain actions (abstract) ────────────────────────────
\* Each action below is a narrow abstraction of a sub-FSM transition.
\* The sub-FSM's detailed behaviour is verified in its own spec; here
\* we only move enough state to observe cross-spec properties.

StartTurn ==
    /\ ksm_phase \in {"Running", "Failing"}
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
    \* RFC-0065 Phase 5.1.b projections — reset for the new turn.
    /\ kcaf_attempt_phase' = "idle"
    /\ kts_surface_ready' = FALSE
    /\ kpto_phase' = "idle"
    /\ UNCHANGED <<ksm_phase>>

MeasurementBroadcast ==                  \* Context_measured (priority 5)
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement = 0            \* exactly once per turn (P3-like)
    /\ shared_measurement' = turn_tick    \* any unique, nonzero value
    /\ measurement_turn' = turn_tick
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, kmc_compaction, turn_tick,
                   kcaf_attempt_phase, kts_surface_ready, kpto_phase>>

DecideGuard ==
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement /= 0
    /\ kdp_decision = "undecided"
    /\ kdp_decision' = "guard_ok"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

SelectToolPolicy ==
    /\ ktc_turn_phase = "prompting"
    /\ kdp_decision = "guard_ok"
    /\ kdp_decision' = "tool_policy_selected"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

\* ComputeToolSurface — B2 (KeeperToolSurface) projection step.  Runs
\* after a tool policy is selected and before the cascade attempts
\* anything; produces the kts_surface_ready ghost that ToolSurfaceFeedsAttempt
\* checks downstream.  Mirrors the keeper_run_tools.ml::compute_tool_surface
\* call at the start of each Agent.run loop iteration.
ComputeToolSurface ==
    /\ ktc_turn_phase = "prompting"
    /\ shared_measurement /= 0
    /\ kdp_decision = "tool_policy_selected"
    /\ ~kts_surface_ready
    /\ kts_surface_ready' = TRUE
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, kmc_compaction, shared_measurement,
                   measurement_turn, turn_tick, kcaf_attempt_phase,
                   kpto_phase>>

StartCascadeSelection ==
    /\ ktc_turn_phase = "prompting"
    /\ kdp_decision = "tool_policy_selected"
    /\ shared_measurement /= 0
    /\ kcl_cascade_state = "idle"
    \* B2 dependency: the tool surface must be ready before cascade
    \* selection.  Enforces ToolSurfaceFeedsAttempt at the producer.
    /\ kts_surface_ready
    /\ kcl_cascade_state' = "selecting"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

SelectCascade ==
    /\ kcl_cascade_state = "selecting"
    /\ shared_measurement /= 0
    /\ kcl_cascade_state' = "trying"
    /\ ktc_turn_phase' = "executing"
    \* B1 transition: composite "trying" maps to KCAF "attempting".
    /\ kcaf_attempt_phase' = "attempting"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick,
                   kts_surface_ready, kpto_phase>>

GateRejected ==
    /\ ksm_phase = "Running"
    /\ ktc_turn_phase = "executing"
    /\ kdp_decision = "tool_policy_selected"
    /\ kcl_cascade_state = "trying"
    /\ kdp_decision' = "gate_rejected"
    /\ ktc_turn_phase' = "finalizing"
    \* B1 transition: gate rejection ends the attempt at the cascade
    \* boundary — KCAF reaches a terminal state.
    /\ kcaf_attempt_phase' = "terminal"
    /\ UNCHANGED kcl_cascade_state
    /\ UNCHANGED <<ksm_phase, kmc_compaction, shared_measurement,
                   measurement_turn, turn_tick, kts_surface_ready,
                   kpto_phase>>

CascadeDone ==
    /\ ksm_phase = "Running"
    /\ kcl_cascade_state = "trying"
    /\ kcl_cascade_state' = "done"
    /\ ktc_turn_phase' = "finalizing"
    \* B1 transition: cascade success → KCAF "terminal".
    /\ kcaf_attempt_phase' = "terminal"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick,
                   kts_surface_ready, kpto_phase>>

CascadeExhausted ==
    /\ ksm_phase = "Running"
    /\ kcl_cascade_state = "trying"
    /\ kcl_cascade_state' = "exhausted"
    /\ ktc_turn_phase' = "finalizing"
    \* B1 transition: cascade exhaustion → KCAF "terminal".
    /\ kcaf_attempt_phase' = "terminal"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick,
                   kts_surface_ready, kpto_phase>>

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
    \* B3 transition: post-turn pipeline (compaction → wireins → persist)
    \* enters its "active" phase here.  KCAF stays "terminal" through
    \* the post-turn run so PostTurnConsumesAttempt holds.
    /\ kpto_phase' = "active"
    /\ UNCHANGED <<ksm_phase, kmc_compaction, turn_tick,
                   kcaf_attempt_phase, kts_surface_ready>>

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
    /\ UNCHANGED <<shared_measurement, measurement_turn, turn_tick,
                   kcaf_attempt_phase, kts_surface_ready, kpto_phase>>

FinishCompaction ==
    /\ ksm_phase = "Compacting"
    /\ kmc_compaction = "compacting"
    /\ ksm_phase' = "Running"
    /\ ktc_turn_phase' = "idle"
    /\ kmc_compaction' = "done"
    \* B3 transition: end of post-turn → checkpoint persisted.
    \* StartTurn resets kpto_phase back to "idle" for the next turn.
    /\ kpto_phase' = "persisted"
    /\ UNCHANGED <<kdp_decision, kcl_cascade_state, shared_measurement,
                   measurement_turn, turn_tick, kcaf_attempt_phase,
                   kts_surface_ready>>

EnterFailing ==
    /\ ksm_phase = "Running"
    /\ ksm_phase' = "Failing"
    /\ UNCHANGED <<ktc_turn_phase, kdp_decision, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

ClearFailing ==
    /\ ksm_phase = "Failing"
    /\ ksm_phase' = "Running"
    /\ UNCHANGED <<ktc_turn_phase, kdp_decision, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

\* Overflowed orchestration (Context overflow detected).
\* Runtime truth: parent phase moves to Overflowed first. The in-flight turn
\* and cascade projection remain live until the later compaction retry path
\* rewrites them.
EnterOverflowed ==
    /\ ksm_phase = "Running"
    /\ ktc_turn_phase = "executing"
    /\ kdp_decision = "tool_policy_selected"
    /\ kcl_cascade_state = "trying"
    /\ ksm_phase' = "Overflowed"
    /\ UNCHANGED <<ktc_turn_phase, kdp_decision, kcl_cascade_state,
                   kmc_compaction, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

\* Overflowed -> Compacting (Start_compaction entry action).
\* Atomically moves KSM, KTC, KMC so CompactionAtomicity is preserved:
\* kmc_compaction="compacting" is never observed with ksm_phase="Overflowed"
\* at a reached state.
OverflowedAutoCompact ==
    /\ ksm_phase = "Overflowed"
    /\ ksm_phase' = "Compacting"
    /\ ktc_turn_phase' = "compacting"
    /\ kmc_compaction' = "compacting"
    \* The in-flight cascade attempt is interrupted by the overflow
    \* event — KCAF moves to "terminal".  Mirrors the keeper_turn_driver
    \* abort path that surfaces the overflow as a terminal outcome.
    /\ kcaf_attempt_phase' = "terminal"
    /\ UNCHANGED <<kdp_decision, kcl_cascade_state, shared_measurement,
                   measurement_turn, turn_tick, kts_surface_ready,
                   kpto_phase>>

\* ── Next-state relation ──────────────────────────────────

Next ==
    \/ StartTurn
    \/ MeasurementBroadcast
    \/ DecideGuard
    \/ SelectToolPolicy
    \/ ComputeToolSurface
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
    /\ WF_vars(ComputeToolSurface)
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
\* lifecycle atomicity in keeper_post_turn.ml — the post-turn lifecycle
\* orchestration (apply_post_turn_lifecycle_with_resilience_handles and
\* the compaction/rollover/wirein steps it sequences; cited by symbol,
\* not line — iter 64 N-2.a, converted in the iter 85 scattered-singles
\* line-ref sweep).
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
\* The currently bound measurement must belong to the live turn. This is
\* the small-state observer projection of the runtime's stronger
\* measurement-bind monotonicity check.
EventPriorityMonotone ==
    (shared_measurement = 0) \/ (measurement_turn = turn_tick)

\* ── RFC-0065 Phase 5.1.b joint invariants ────────────────
\* Three predicates spanning the existing 5 sub-FSMs and the three new
\* RFC-0065 sub-FSMs (B1/B2/B3).  Per RFC §3.4 these stay weak —
\* predicates over projections only, no enumeration of the full
\* product state space.

\* I5 — AttemptFSMRespectsAdmission (RFC §3.4)
\* B1.KCAF cannot enter "attempting" unless the admission gate
\* (measurement hub here, which is the in-spec projection of
\* KeeperAdmissionLiveness) has fired in the current turn.
AttemptFSMRespectsAdmission ==
    (kcaf_attempt_phase = "attempting") =>
        (shared_measurement /= 0 /\ measurement_turn = turn_tick)

\* I6 — ToolSurfaceFeedsAttempt (RFC §3.4)
\* B2.KTS must have produced a non-empty surface (kts_surface_ready)
\* before B1.KCAF enters "attempting".  Models the producer/consumer
\* dependency: an empty surface cannot feed a cascade attempt.
ToolSurfaceFeedsAttempt ==
    (kcaf_attempt_phase = "attempting") => kts_surface_ready

\* I7 — PostTurnConsumesAttempt (RFC §3.4)
\* B3.KPTO begins only when B1.KCAF has reached a terminal state.
\* "active" must not be observed alongside an in-flight attempt;
\* either the cascade was not attempted this turn (kcaf = "idle")
\* or it terminated before post-turn started.
PostTurnConsumesAttempt ==
    (kpto_phase = "active") => (kcaf_attempt_phase /= "attempting")

SafetyInvariant ==
    /\ TypeOK
    /\ PhaseTurnAlignment
    /\ NoCascadeBeforeMeasurement
    /\ CompactionAtomicity
    /\ EventPriorityMonotone
    /\ AttemptFSMRespectsAdmission
    /\ ToolSurfaceFeedsAttempt
    /\ PostTurnConsumesAttempt

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
                   shared_measurement, measurement_turn, turn_tick,
                   kcaf_attempt_phase, kts_surface_ready, kpto_phase>>

NextBuggyCascade == Next \/ BugCascadeBeforeMeasurement

\* NextBuggyCompaction — KMC advances without KSM/KTC coupling
\* Violates: PhaseTurnAlignment and CompactionAtomicity
BugCompactionDesync ==
    /\ ksm_phase = "Running"
    /\ kmc_compaction = "accumulating"
    /\ kmc_compaction' = "compacting"     \* BUG: KSM and KTC stay put
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, shared_measurement, measurement_turn,
                   turn_tick, kcaf_attempt_phase, kts_surface_ready,
                   kpto_phase>>

NextBuggyCompaction == Next \/ BugCompactionDesync

\* RFC-0065 Phase 5.1.b bug actions — each violates a distinct
\* joint invariant introduced by this phase.

\* BugAttemptWithoutSurface — cascade selection bypasses the
\* ComputeToolSurface step entirely: the clean StartCascadeSelection
\* requires kts_surface_ready, this variant jumps idle → trying with
\* the surface still empty.  Models a refactor that elides the
\* compute_tool_surface call between SelectToolPolicy and cascade
\* dispatch.  Violates ToolSurfaceFeedsAttempt.
BugAttemptWithoutSurface ==
    /\ ktc_turn_phase = "prompting"
    /\ kdp_decision = "tool_policy_selected"
    /\ shared_measurement /= 0
    /\ kcl_cascade_state = "idle"
    /\ ~kts_surface_ready
    /\ kcl_cascade_state' = "trying"
    /\ ktc_turn_phase' = "executing"
    /\ kcaf_attempt_phase' = "attempting"
    /\ UNCHANGED <<ksm_phase, kdp_decision, kmc_compaction,
                   shared_measurement, measurement_turn, turn_tick,
                   kts_surface_ready, kpto_phase>>

\* BugPostTurnDuringAttempt — post-turn pipeline starts while the
\* cascade is still in flight.  Models a control-flow refactor that
\* fires the post-turn finalizer before the attempt FSM reaches a
\* terminal state.  Violates PostTurnConsumesAttempt.
BugPostTurnDuringAttempt ==
    /\ kcaf_attempt_phase = "attempting"
    /\ kpto_phase = "idle"
    /\ kpto_phase' = "active"
    /\ UNCHANGED <<ksm_phase, ktc_turn_phase, kdp_decision,
                   kcl_cascade_state, kmc_compaction, shared_measurement,
                   measurement_turn, turn_tick, kcaf_attempt_phase,
                   kts_surface_ready>>

NextBuggyAttempt  == Next \/ BugAttemptWithoutSurface
NextBuggyPostTurn == Next \/ BugPostTurnDuringAttempt

SpecBuggyCascade  == Init /\ [][NextBuggyCascade]_vars  /\ Fairness
SpecBuggyCompaction == Init /\ [][NextBuggyCompaction]_vars /\ Fairness
SpecBuggyAttempt  == Init /\ [][NextBuggyAttempt]_vars  /\ Fairness
SpecBuggyPostTurn == Init /\ [][NextBuggyPostTurn]_vars /\ Fairness

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
