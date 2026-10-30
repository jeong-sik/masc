------------------------ MODULE ShellIRFirstClass ------------------------
(* Shell IR structural-boundary model.

   Shell IR parses an explicit command shape, validates its structural fields,
   binds an objective sandbox target, and dispatches it. Authorization is not a
   Shell IR state; the Keeper Gate receives the complete external-effect request
   at the product boundary.

   The buggy relation permits dispatch after structural validation but before
   sandbox binding. SafetyInvariant must reject that trace.
*)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxCmds

Raw                == "Raw"
Parsed             == "Parsed"
StructureValidated == "StructureValidated"
SandboxBound       == "SandboxBound"
Dispatched         == "Dispatched"

States == {Raw, Parsed, StructureValidated, SandboxBound, Dispatched}
CmdIds == 1..MaxCmds

VARIABLES
    state,
    structure_valid,
    sandbox_bound

vars == <<state, structure_valid, sandbox_bound>>

TypeOK ==
    /\ state           \in [CmdIds -> States]
    /\ structure_valid \in [CmdIds -> BOOLEAN]
    /\ sandbox_bound   \in [CmdIds -> BOOLEAN]

Init ==
    /\ state           = [c \in CmdIds |-> Raw]
    /\ structure_valid = [c \in CmdIds |-> FALSE]
    /\ sandbox_bound   = [c \in CmdIds |-> FALSE]

Parse(c) ==
    /\ state[c] = Raw
    /\ state' = [state EXCEPT ![c] = Parsed]
    /\ UNCHANGED <<structure_valid, sandbox_bound>>

ValidateStructure(c) ==
    /\ state[c] = Parsed
    /\ state' = [state EXCEPT ![c] = StructureValidated]
    /\ structure_valid' = [structure_valid EXCEPT ![c] = TRUE]
    /\ UNCHANGED sandbox_bound

BindSandbox(c) ==
    /\ state[c] = StructureValidated
    /\ structure_valid[c]
    /\ state' = [state EXCEPT ![c] = SandboxBound]
    /\ sandbox_bound' = [sandbox_bound EXCEPT ![c] = TRUE]
    /\ UNCHANGED structure_valid

Dispatch(c) ==
    /\ state[c] = SandboxBound
    /\ structure_valid[c]
    /\ sandbox_bound[c]
    /\ state' = [state EXCEPT ![c] = Dispatched]
    /\ UNCHANGED <<structure_valid, sandbox_bound>>

Done ==
    /\ \A c \in CmdIds : state[c] = Dispatched
    /\ UNCHANGED vars

Next ==
    \/ \E c \in CmdIds :
        \/ Parse(c)
        \/ ValidateStructure(c)
        \/ BindSandbox(c)
        \/ Dispatch(c)
    \/ Done

Spec == Init /\ [][Next]_vars

DispatchWithoutSandbox(c) ==
    /\ state[c] = StructureValidated
    /\ structure_valid[c]
    /\ ~sandbox_bound[c]
    /\ state' = [state EXCEPT ![c] = Dispatched]
    /\ UNCHANGED <<structure_valid, sandbox_bound>>

NextBuggy ==
    \/ Next
    \/ \E c \in CmdIds : DispatchWithoutSandbox(c)
    \/ Done

SpecBuggy == Init /\ [][NextBuggy]_vars

SafetyInvariant ==
    \A c \in CmdIds :
        state[c] = Dispatched => structure_valid[c] /\ sandbox_bound[c]

============================================================================
