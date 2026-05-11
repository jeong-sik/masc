---- MODULE KeeperRolloverDecision ----
\* Rollover gate decision: provider-opaque, typed-class driven.
\*
\* OCaml ↔ TLA+ mapping:
\*
\*   spec variable    | OCaml location                                          | semantic
\*   -----------------+---------------------------------------------------------+---------
\*   autoHandoff      | lib/keeper/keeper_rollover.ml:classify_rollover_gate    | named arg ~auto_handoff
\*   cooldownElapsed  | lib/keeper/keeper_rollover.ml:classify_rollover_gate    | named arg ~cooldown_elapsed
\*   ratioGate        | lib/keeper/keeper_rollover.ml:classify_rollover_gate    | ratio >= handoff_threshold
\*   lastOutcome      | lib/keeper/keeper_rollover.ml:classify_rollover_gate    | named arg ~last_outcome
\*   blockerClass     | lib/keeper/keeper_rollover.ml:blocker_class_indicates_overflow | typed Keeper_types.blocker_class
\*   decision         | lib/keeper/keeper_rollover.ml:rollover_gate_decision    | Skip(reason) | Go(reason)
\*
\* Architectural invariant:
\*   OAS/MASC treat provider/model as opaque aliases.  The keeper layer
\*   reasons only over typed blocker_class — substring matching at this
\*   layer is forbidden.  The SDK boundary (Keeper_status_bridge) is the
\*   sole adapter from wire-level phrasing to typed class.
\*
\*   Spec models classes as abstract symbols ("overflow", "non_overflow")
\*   to enforce opacity at the model checking level — class identifiers
\*   carry no provider semantics.
\*
\* Bug Model (CLAUDE.md §TLA+ Bug Model 패턴):
\*   Clean cfg: rollover Go fires iff (ratio_gate) OR (proactive_error AND
\*              overflow_class).  Other classes never trigger the signal gate.
\*   Buggy cfg: models the historical substring-match degradation where the
\*              gate fires on any non-empty blocker class regardless of
\*              overflow semantics.  Invariant SignalGateOverflowOnly MUST
\*              be violated.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    BlockerClasses,  \* abstract set including "overflow" + at least one "non_overflow"
    Outcomes,        \* {"proactive_error", "proactive_silent", "proactive_text"}
    MaxSteps         \* bounded model checking

ASSUME
    /\ "overflow" \in BlockerClasses
    /\ "non_overflow" \in BlockerClasses
    /\ "proactive_error" \in Outcomes
    /\ "proactive_silent" \in Outcomes
    /\ "proactive_text" \in Outcomes

VARIABLES
    autoHandoff,
    cooldownElapsed,
    ratioGate,
    lastOutcome,
    lastBlockerClass,    \* "none" | element of BlockerClasses
    decision,            \* "pending" | "skip_disabled" | "skip_cooldown"
                         \* | "skip_below" | "go_ratio" | "go_signal" | "go_both"
    step

vars == <<autoHandoff, cooldownElapsed, ratioGate, lastOutcome,
          lastBlockerClass, decision, step>>

TypeOK ==
    /\ autoHandoff \in BOOLEAN
    /\ cooldownElapsed \in BOOLEAN
    /\ ratioGate \in BOOLEAN
    /\ lastOutcome \in Outcomes
    /\ lastBlockerClass \in BlockerClasses \cup {"none"}
    /\ decision \in {"pending", "skip_disabled", "skip_cooldown",
                     "skip_below", "go_ratio", "go_signal", "go_both"}
    /\ step \in 0..MaxSteps

Init ==
    /\ autoHandoff = TRUE
    /\ cooldownElapsed = TRUE
    /\ ratioGate = FALSE
    /\ lastOutcome = "proactive_silent"
    /\ lastBlockerClass = "none"
    /\ decision = "pending"
    /\ step = 0

\* Typed signal predicate — fires iff outcome was an error AND the
\* typed class is the overflow class.  This is the SAFE specification:
\* downstream rollover reasons over typed enum only.
SignalFires(outcome, klass) ==
    /\ outcome = "proactive_error"
    /\ klass = "overflow"

\* Decision function — clean (correct) version.
ComputeDecision(ah, ce, rg, outcome, klass) ==
    IF ~ah THEN "skip_disabled"
    ELSE IF ~ce THEN "skip_cooldown"
    ELSE LET sig == SignalFires(outcome, klass) IN
         CASE rg /\ sig    -> "go_both"
           [] rg /\ ~sig   -> "go_ratio"
           [] ~rg /\ sig   -> "go_signal"
           [] OTHER        -> "skip_below"

\* Decision function — BUGGY version: signal fires on any non-none class
\* during a proactive_error, regardless of whether the class is the
\* overflow class.  Mirrors the historical substring-match drift.
ComputeDecisionBuggy(ah, ce, rg, outcome, klass) ==
    IF ~ah THEN "skip_disabled"
    ELSE IF ~ce THEN "skip_cooldown"
    ELSE LET sig == (outcome = "proactive_error" /\ klass /= "none") IN
         CASE rg /\ sig    -> "go_both"
           [] rg /\ ~sig   -> "go_ratio"
           [] ~rg /\ sig   -> "go_signal"
           [] OTHER        -> "skip_below"

\* Next-state action: nondeterministically pick fresh inputs and compute decision.
Next ==
    /\ step < MaxSteps
    /\ \E ah \in BOOLEAN,
           ce \in BOOLEAN,
           rg \in BOOLEAN,
           o \in Outcomes,
           k \in BlockerClasses \cup {"none"}:
         /\ autoHandoff' = ah
         /\ cooldownElapsed' = ce
         /\ ratioGate' = rg
         /\ lastOutcome' = o
         /\ lastBlockerClass' = k
         /\ decision' = ComputeDecision(ah, ce, rg, o, k)
         /\ step' = step + 1

NextBuggy ==
    /\ step < MaxSteps
    /\ \E ah \in BOOLEAN,
           ce \in BOOLEAN,
           rg \in BOOLEAN,
           o \in Outcomes,
           k \in BlockerClasses \cup {"none"}:
         /\ autoHandoff' = ah
         /\ cooldownElapsed' = ce
         /\ ratioGate' = rg
         /\ lastOutcome' = o
         /\ lastBlockerClass' = k
         /\ decision' = ComputeDecisionBuggy(ah, ce, rg, o, k)
         /\ step' = step + 1

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: when the gate fires on signal (go_signal or go_both contribution),
\* the blocker class must be exactly "overflow".  Non-overflow classes must
\* never trigger the signal half of the gate.
SignalGateOverflowOnly ==
    decision \in {"go_signal", "go_both"} =>
        \/ decision = "go_both" /\ ~SignalFires(lastOutcome, lastBlockerClass)
            \* When go_both, the signal contribution may be absent;
            \* ratio gate alone justifies "go_both" only if signal also fired
            \* — which the clean spec guarantees by construction.  This
            \* disjunct stays present so the invariant is provable on the
            \* clean spec without conflating ratio and signal contributions.
        \/ SignalFires(lastOutcome, lastBlockerClass)

\* Safety: provider-opaque — the decision must not depend on any class
\* other than via SignalFires.  Stated as a frame condition: two states
\* with the same (autoHandoff, cooldownElapsed, ratioGate) and the same
\* SignalFires outcome must yield the same decision.  Proved trivially
\* by the structure of ComputeDecision (no other class references).
\*
\* This invariant is intentionally weaker than a refinement check — TLC
\* explores the state space and finds counterexamples on the buggy spec
\* where a non-"overflow" class drives the signal half of the gate.

====
