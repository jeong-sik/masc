------------------------ MODULE ShellIRFirstClass ------------------------
(* TLA+ spec for RFC-0160 G6 — Shell IR carries decision invariant.

   Models the lifecycle of one shell command through the four-state
   pipeline the plan distinguishes:

     Raw                  raw bash string at the boundary
     ParsedNoDecision     Shell_ir.t built, no risk_class stamped
     Decided              phantom-decided envelope carries risk_class
     Dispatched           dispatched via Exec_dispatch.dispatch_decided

   Bug Model pattern (memory/feedback_tla-spec-audit-outcome-trichotomy):
     Clean cfg: SafetyInvariant holds on Next  → "no error"
     Buggy cfg: SafetyInvariant fails on NextBuggy due to
                DispatchWithoutDecision arm     → "invariant violated"
     Both outcomes must hold for the spec to be useful.

   Source: shell-ir-first-class-promotion-todo-2026-05-23.html §S7.
*)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxCmds       \* model bound on number of in-flight commands

\* Symbolic risk classes mirroring lib/exec/shell_ir_risk.ml.
R0 == "R0_Read"
R1 == "R1_Reversible_mutation"
R2 == "R2_Irreversible"
RX == "Destructive_protected"

RiskClasses == {R0, R1, R2, RX}

\* Pipeline states.
Raw                == "Raw"
ParsedNoDecision   == "ParsedNoDecision"
Decided            == "Decided"
Dispatched         == "Dispatched"

States == {Raw, ParsedNoDecision, Decided, Dispatched}

VARIABLES
    state,        \* function: cmd_id -> state
    risk          \* partial function: cmd_id -> RiskClasses (None when undecided)

vars == <<state, risk>>

CmdIds == 1..MaxCmds

\* "None" sentinel for risk when not yet decided. We model this with a
\* fresh string, since TLA+ functions are total: the field always has a
\* value but only Decided/Dispatched states require a real RiskClass.
NoRisk == "NoRisk"
RiskOrNone == RiskClasses \cup {NoRisk}

TypeOK ==
    /\ state \in [CmdIds -> States]
    /\ risk  \in [CmdIds -> RiskOrNone]

Init ==
    /\ state = [c \in CmdIds |-> Raw]
    /\ risk  = [c \in CmdIds |-> NoRisk]

\* ── Actions (clean pipeline) ───────────────────────────────────────

Parse(c) ==
    /\ state[c] = Raw
    /\ state' = [state EXCEPT ![c] = ParsedNoDecision]
    /\ risk'  = risk

Classify(c, r) ==
    /\ state[c] = ParsedNoDecision
    /\ r \in RiskClasses
    /\ state' = [state EXCEPT ![c] = Decided]
    /\ risk'  = [risk  EXCEPT ![c] = r]

Dispatch(c) ==
    /\ state[c] = Decided
    /\ risk[c] \in RiskClasses
    /\ state' = [state EXCEPT ![c] = Dispatched]
    /\ risk'  = risk

\* Quiescence: every command has finished dispatch. Modeled as an
\* explicit stuttering action so the model checker's deadlock detector
\* does not flag the natural terminal state as a violation.
Done ==
    /\ \A c \in CmdIds : state[c] = Dispatched
    /\ UNCHANGED vars

\* Clean transition relation: only the three lawful actions plus
\* the explicit quiescence stutter.
Next ==
    \/ \E c \in CmdIds :
        \/ Parse(c)
        \/ \E r \in RiskClasses : Classify(c, r)
        \/ Dispatch(c)
    \/ Done

Spec == Init /\ [][Next]_vars

\* ── Bug Model action ──────────────────────────────────────────────
\*
\* Models the anti-pattern where a caller jumps from ParsedNoDecision
\* straight to Dispatched, skipping classification. RFC-0160 G6 forbids
\* this; phantom envelope makes it a compile-time error in OCaml. The
\* spec catches it as a runtime violation of SafetyInvariant.

DispatchWithoutDecision(c) ==
    /\ state[c] = ParsedNoDecision
    /\ state' = [state EXCEPT ![c] = Dispatched]
    /\ risk'  = risk     \* still NoRisk — invariant must catch this

NextBuggy ==
    \/ Next
    \/ \E c \in CmdIds : DispatchWithoutDecision(c)
    \/ Done

SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariant ──────────────────────────────────────────────

SafetyInvariant ==
    \A c \in CmdIds :
        state[c] = Dispatched => risk[c] \in RiskClasses

============================================================================
