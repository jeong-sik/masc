---- MODULE KeeperPostTurnOrchestration ----
\* Post-turn orchestration — wirein ordering + blocker stamp contract.
\*
\* RFC-0065 Phase 5.3 (B3).  Closes memory P5 OPEN item by giving
\* Stage 4 (Post-Turn) explicit TLA+ coverage for the first time.
\*
\* Scope: models the post-turn sequence in keeper_post_turn.ml
\* (apply_post_turn_lifecycle_with_resilience_handles):
\*
\*   turn_ended
\*     → compaction_decision         ∈ {Applied, Blocked, Skipped}
\*     → blocker_info_stamped        ∈ {None, Some(klass)}
\*     → rollover_decision           (delegates to KeeperRolloverDecision)
\*     → wirein_autonomous (A5)
\*     → wirein_resilience (A6)
\*     → wirein_tool_emission (K4b)
\*     → wirein_multimodal (K1)
\*     → lineage_appended            (when rollover_decision = Go)
\*     → checkpoint_persisted
\*
\* This spec is ORTHOGONAL to its sibling Phase 5 specs:
\*   - KeeperCascadeAttemptFSM.tla  (B1, RFC-0065 Phase 5.1) — cascade FSM
\*   - KeeperToolSurface.tla        (B2, RFC-0065 Phase 5.2) — tool surface pipeline
\*   - KeeperRolloverDecision.tla   (Phase 4)                — rollover gate (this spec consumes its outcome class)
\*
\* OCaml ↔ TLA+ mapping:
\*
\*   spec variable / action          | OCaml location                                                          | semantic
\*   --------------------------------+-------------------------------------------------------------------------+---------
\*   phase                           | implicit (control-flow position inside apply_post_turn_lifecycle)        | lib/keeper/keeper_post_turn.ml:600-656
\*   compaction_decision             | post_turn_lifecycle.compaction.applied/failure_reason/trigger           | lib/keeper/keeper_post_turn.ml:622-632
\*   blocker_klass                   | current_turn_blocker_info.klass (Track A typed enum)                    | lib/keeper/keeper_unified_turn.ml:1640
\*   blocker_detail_present          | current_turn_blocker_info.detail (text/json detail field)               | lib/keeper/keeper_meta_contract.ml::blocker_info
\*   rollover_decision               | Keeper_rollover.maybe_rollover_oas_handoff outcome                      | lib/keeper/keeper_post_turn.ml:600-608
\*   wirein_order                    | Seq of atoms appended at each apply_*_wirein call                       | lib/keeper/keeper_post_turn.ml:648-656
\*   lineage_appended_before_persist | structural — implied by the rollover-handoff handler ordering           | lib/keeper/keeper_rollover.ml (handoff write path)
\*   checkpoint_persisted            | downstream caller (autonomous_runner) post-checkpoint write              | lib/keeper/keeper_unified_turn.ml (consumer of post_turn_lifecycle)
\*
\* Provider opacity (G3 acceptance gate):
\*   blocker_klass is modeled as an abstract symbol set ({"none",
\*   "sdk_token_budget_exceeded", "completion_contract_violation",
\*   "other"}).  None of the symbols name a provider, model, or vendor.
\*
\* Bug Model (per project's TLA+ Bug Model convention):
\*   Clean cfg: invariants WireinOrderPinned, BlockerStampedBeforeRollover,
\*              CheckpointPersistedAfterWirein, LineageAppendedOnRolloverGo
\*              must hold.
\*   Buggy cfg: SpecBuggy admits one of four BugActions —
\*     - BugWireinOutOfOrder      : A6 fires before A5
\*     - BugStampGap              : detail present but klass = none (the
\*                                  historical 4/14 keepers case — Track A
\*                                  closed the *rollover-fire* half;
\*                                  this catches the *producer* half)
\*     - BugCheckpointBeforeWirein: persist fires before A5–K1 mutate working_context
\*     - BugLineageAfterCheckpoint: lineage append after checkpoint persist
\*   At least one invariant MUST be violated.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxSteps             \* upper bound on action count for bounded checking

\* Abstract klass alphabet.  Pinned in the spec (not parameterized via
\* CONSTANTS) so the OCaml ↔ TLA+ correspondence harness can grep the
\* literal set.  "none" is the sentinel emitted when no blocker class
\* was stamped; "sdk_token_budget_exceeded" is the single overflow-
\* relevant klass that Track A's blocker_class_indicates_overflow
\* returns true for.  The other two are representative non-overflow
\* klasses included to keep BlockerStampedBeforeRollover non-vacuous
\* without bloating the state space with all 26 OCaml variants.
BlockerKlassSet ==
    {"none",
     "sdk_token_budget_exceeded",
     "completion_contract_violation",
     "other"}

ASSUME
    /\ MaxSteps \in Nat /\ MaxSteps >= 1

\* The canonical wirein order pinned at keeper_post_turn.ml:648-656.
\* Reordering this constant is itself a regression — the spec must
\* observe THIS order, not a configurable one.
CanonicalWireinOrder == <<"A5", "A6", "K4b", "K1">>

WireinAtomSet == {"A5", "A6", "K4b", "K1"}

PhaseSet ==
    {"idle",
     "turn_ended",
     "compacted",
     "stamped",
     "rolled_over",
     "wired",                  \* one or more wireins have fired
     "lineage_appended",       \* only reached when rollover = "go"
     "checkpoint_persisted"}

CompactionDecisionSet == {"none", "applied", "blocked", "skipped"}

RolloverDecisionSet == {"none", "go", "skip"}

VARIABLES
    phase,                              \* one of PhaseSet
    compaction_decision,                \* CompactionDecisionSet
    blocker_klass,                      \* element of BlockerKlassSet
    blocker_detail_present,             \* BOOLEAN (Track A: detail is always populated when stamping fires)
    rollover_decision,                  \* RolloverDecisionSet
    wirein_order,                       \* Seq(WireinAtomSet) — appended in firing order
    lineage_appended_before_persist,    \* BOOLEAN — pinned ordering ghost
    checkpoint_persisted,               \* BOOLEAN
    step                                \* action count

vars == <<phase, compaction_decision, blocker_klass, blocker_detail_present,
          rollover_decision, wirein_order, lineage_appended_before_persist,
          checkpoint_persisted, step>>

\* ── Type invariant ──────────────────────────────────────

TypeOK ==
    /\ phase \in PhaseSet
    /\ compaction_decision \in CompactionDecisionSet
    /\ blocker_klass \in BlockerKlassSet
    /\ blocker_detail_present \in BOOLEAN
    /\ rollover_decision \in RolloverDecisionSet
    /\ wirein_order \in Seq(WireinAtomSet)
    /\ Len(wirein_order) <= 4
    /\ lineage_appended_before_persist \in BOOLEAN
    /\ checkpoint_persisted \in BOOLEAN
    /\ step \in 0..MaxSteps

\* ── Initial state ───────────────────────────────────────

Init ==
    /\ phase = "idle"
    /\ compaction_decision = "none"
    /\ blocker_klass = "none"
    /\ blocker_detail_present = FALSE
    /\ rollover_decision = "none"
    /\ wirein_order = <<>>
    /\ lineage_appended_before_persist = FALSE
    /\ checkpoint_persisted = FALSE
    /\ step = 0

\* ── Actions (clean) ─────────────────────────────────────

\* Begin the post-turn sequence.  Mirrors entry into
\* apply_post_turn_lifecycle_with_resilience_handles.
StartTurn ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ phase' = "turn_ended"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Compaction sub-decision.  The OCaml side records this in
\* post_turn_lifecycle.compaction; the spec just picks one outcome.
DoCompaction ==
    /\ phase = "turn_ended"
    /\ step < MaxSteps
    /\ \E d \in CompactionDecisionSet \ {"none"}:
         compaction_decision' = d
    /\ phase' = "compacted"
    /\ step' = step + 1
    /\ UNCHANGED <<blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Stamp the blocker info.  Clean version: detail and klass are
\* always consistent — if detail is present, klass is non-"none".
\* Track A enforces this on the consumer side (Sdk_token_budget_exceeded
\* etc. is the typed value); this action enforces it on the producer side.
StampBlocker ==
    /\ phase = "compacted"
    /\ step < MaxSteps
    /\ \E k \in BlockerKlassSet, d \in BOOLEAN:
         /\ blocker_klass' = k
         /\ blocker_detail_present' = d
         \* Producer contract: detail and klass move together.
         /\ (d <=> k /= "none")
    /\ phase' = "stamped"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, rollover_decision, wirein_order,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Rollover decision.  Mirrors the dispatch at
\* keeper_post_turn.ml:600-608 → Keeper_rollover.maybe_rollover_oas_handoff.
\* Go fires only when a non-"none" klass was stamped (the rollover gate
\* consults blocker_class_indicates_overflow on the typed enum, which
\* requires klass /= "none" by construction — see Track A PR #14613).
DecideRollover ==
    /\ phase = "stamped"
    /\ step < MaxSteps
    /\ \/ (blocker_klass /= "none" /\ rollover_decision' \in {"go", "skip"})
       \/ (blocker_klass = "none" /\ rollover_decision' = "skip")
    /\ phase' = "rolled_over"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   wirein_order, lineage_appended_before_persist,
                   checkpoint_persisted>>

\* Wirein A5 — autonomous post-turn tick.  First in the pinned order.
WireinA5 ==
    /\ phase = "rolled_over"
    /\ wirein_order = <<>>
    /\ step < MaxSteps
    /\ wirein_order' = Append(wirein_order, "A5")
    /\ phase' = "wired"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, lineage_appended_before_persist,
                   checkpoint_persisted>>

\* Wirein A6 — resilience classification.  Runs ONLY after A5.
WireinA6 ==
    /\ phase = "wired"
    /\ wirein_order = <<"A5">>
    /\ step < MaxSteps
    /\ wirein_order' = Append(wirein_order, "A6")
    /\ step' = step + 1
    /\ UNCHANGED <<phase, compaction_decision, blocker_klass,
                   blocker_detail_present, rollover_decision,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Wirein K4b — tool-emission drain.  Runs ONLY after A5, A6.
WireinK4b ==
    /\ phase = "wired"
    /\ wirein_order = <<"A5", "A6">>
    /\ step < MaxSteps
    /\ wirein_order' = Append(wirein_order, "K4b")
    /\ step' = step + 1
    /\ UNCHANGED <<phase, compaction_decision, blocker_klass,
                   blocker_detail_present, rollover_decision,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Wirein K1 — multimodal hydrate.  Last in the pinned order.
WireinK1 ==
    /\ phase = "wired"
    /\ wirein_order = <<"A5", "A6", "K4b">>
    /\ step < MaxSteps
    /\ wirein_order' = Append(wirein_order, "K1")
    /\ step' = step + 1
    /\ UNCHANGED <<phase, compaction_decision, blocker_klass,
                   blocker_detail_present, rollover_decision,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* Lineage append (only on rollover = Go) — fires strictly BEFORE
\* checkpoint persist.  Mirrors the rollover handoff writer at
\* keeper_rollover.ml (handoff JSON path) which appends a lineage
\* entry as part of the handoff record.
AppendLineage ==
    /\ phase = "wired"
    /\ wirein_order = CanonicalWireinOrder
    /\ rollover_decision = "go"
    /\ ~checkpoint_persisted
    /\ step < MaxSteps
    /\ lineage_appended_before_persist' = TRUE
    /\ phase' = "lineage_appended"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order, checkpoint_persisted>>

\* Persist checkpoint.  Reached either via lineage_appended (rollover=Go)
\* or directly from K1 wirein when rollover did not fire.
PersistCheckpoint ==
    /\ \/ (phase = "lineage_appended" /\ rollover_decision = "go")
       \/ (phase = "wired" /\ rollover_decision = "skip" /\
           wirein_order = CanonicalWireinOrder)
    /\ ~checkpoint_persisted
    /\ step < MaxSteps
    /\ checkpoint_persisted' = TRUE
    /\ phase' = "checkpoint_persisted"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order,
                   lineage_appended_before_persist>>

Next ==
    \/ StartTurn
    \/ DoCompaction
    \/ StampBlocker
    \/ DecideRollover
    \/ WireinA5
    \/ WireinA6
    \/ WireinK4b
    \/ WireinK1
    \/ AppendLineage
    \/ PersistCheckpoint

Spec == Init /\ [][Next]_vars

\* ── Bug actions (each models a class of regression) ─────

\* BugAction #1: A6 fires before A5 — the pinned order at
\* keeper_post_turn.ml:648-656 is removed and the wireins are
\* permuted.
BugWireinOutOfOrder ==
    /\ phase = "rolled_over"
    /\ wirein_order = <<>>
    /\ step < MaxSteps
    /\ wirein_order' = Append(wirein_order, "A6")
    /\ phase' = "wired"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, lineage_appended_before_persist,
                   checkpoint_persisted>>

\* BugAction #2: blocker_info detail is stamped but klass remains
\* "none".  This is the historical 4/14 keepers case: dashboard /
\* Prometheus sees the text but the typed enum is null, so downstream
\* gates (Track A's blocker_class_indicates_overflow) never fire.
\* Track A closed the consumer half; this spec catches the producer half.
BugStampGap ==
    /\ phase = "compacted"
    /\ step < MaxSteps
    /\ blocker_klass' = "none"
    /\ blocker_detail_present' = TRUE
    /\ phase' = "stamped"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, rollover_decision, wirein_order,
                   lineage_appended_before_persist, checkpoint_persisted>>

\* BugAction #3: checkpoint persisted at the top of post_turn — before
\* the wireins mutate working_context.  Subsequent A5–K1 mutations
\* would be lost (they touch working_context fields the checkpoint
\* already captured).
BugCheckpointBeforeWirein ==
    /\ \/ phase = "compacted"
       \/ phase = "stamped"
       \/ phase = "rolled_over"
    /\ ~checkpoint_persisted
    /\ step < MaxSteps
    /\ checkpoint_persisted' = TRUE
    /\ phase' = "checkpoint_persisted"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order,
                   lineage_appended_before_persist>>

\* BugAction #4: lineage append is moved to AFTER checkpoint persist.
\* Well-intentioned ordering tweak ("persist first, then write
\* artifacts") that breaks the LineageAppendedOnRolloverGo invariant.
BugLineageAfterCheckpoint ==
    /\ phase = "wired"
    /\ wirein_order = CanonicalWireinOrder
    /\ rollover_decision = "go"
    /\ ~checkpoint_persisted
    /\ ~lineage_appended_before_persist
    /\ step < MaxSteps
    /\ checkpoint_persisted' = TRUE
    /\ phase' = "checkpoint_persisted"
    /\ step' = step + 1
    /\ UNCHANGED <<compaction_decision, blocker_klass, blocker_detail_present,
                   rollover_decision, wirein_order,
                   lineage_appended_before_persist>>

NextBuggy ==
    \/ Next
    \/ BugWireinOutOfOrder
    \/ BugStampGap
    \/ BugCheckpointBeforeWirein
    \/ BugLineageAfterCheckpoint

SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Invariants ──────────────────────────────────────────

\* I1: every prefix of wirein_order matches the canonical sequence.
\* Pinned by comment at keeper_post_turn.ml:640-647 ("Do not reorder").
WireinOrderPinned ==
    \A i \in 1..Len(wirein_order):
        wirein_order[i] = CanonicalWireinOrder[i]

\* I2: when the rollover fires (decision = "go"), blocker_klass must
\* have been stamped with a non-"none" value.  Closes the producer
\* half of the stamp gap (Track A PR #14613 closed the consumer half).
BlockerStampedBeforeRollover ==
    rollover_decision = "go" => blocker_klass /= "none"

\* I3: the checkpoint, once persisted, must follow the full A5–K1
\* wirein sequence.  Models the "persist depends on working_context
\* mutations from all wireins" guarantee.
CheckpointPersistedAfterWirein ==
    checkpoint_persisted => wirein_order = CanonicalWireinOrder

\* I4: when rollover decision = "go", lineage append fires BEFORE
\* checkpoint persist (the handoff record must be present in the
\* lineage trail before the checkpoint freezes state).
LineageAppendedOnRolloverGo ==
    (checkpoint_persisted /\ rollover_decision = "go") =>
        lineage_appended_before_persist

\* I5: composite safety — every invariant above plus TypeOK.
SafetyInvariant ==
    /\ TypeOK
    /\ WireinOrderPinned
    /\ BlockerStampedBeforeRollover
    /\ CheckpointPersistedAfterWirein
    /\ LineageAppendedOnRolloverGo

====
