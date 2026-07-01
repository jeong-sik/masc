---- MODULE KeeperLifecycleGate ----
EXTENDS TLC
(***************************************************************************)
(* KeeperLifecycleGate — RFC-0297 Phase 1 (P0-1) global proactive gate.    *)
(*                                                                         *)
(* Models the keeper cycle decision for the scheduled-autonomous          *)
(* (proactive) turn. Reactive triggers take priority and run regardless   *)
(* of the proactive gate; otherwise a proactive turn runs only when the    *)
(* proactive gate is enabled. The bug: pre-fix the gate was ONLY the       *)
(* per-keeper meta.proactive.enabled — the global switch                   *)
(* (MASC_KEEPER_PROACTIVE_ENABLED / [proactive] enabled in runtime.toml)   *)
(* did not exist, so an operator's global "proactive off" was silently     *)
(* ignored (RFC-0297 P0-1).                                                *)
(*                                                                         *)
(* OCaml <-> TLA+ mapping:                                                  *)
(*   spec variable       | OCaml site                                       *)
(*   --------------------+------------------------------------------------- *)
(*   reactive_trigger    | reactive_triggers <> [] in keeper_cycle_decision *)
(*   global_proactive    | Keeper_lifecycle_gate_env.global().proactive     *)
(*   meta_proactive      | meta.proactive.enabled                           *)
(*   decision            | keeper_cycle_decision verdict/channel            *)
(*                                                                         *)
(* Clean:  Decide gates proactive on global AND meta                        *)
(*         (Keeper_lifecycle_gate.gate_enabled Proactive).                  *)
(* Buggy:  DecideBuggy gates on meta only — the pre-fix short-circuit.      *)
(*                                                                         *)
(* Expected TLC: Clean -> no error; Buggy -> Safety violated (global =     *)
(* FALSE, meta = TRUE, no reactive trigger drives a proactive turn).       *)
(***************************************************************************)

VARIABLES
    reactive_trigger,   \* BOOLEAN: a reactive trigger is pending
    global_proactive,   \* BOOLEAN: MASC_KEEPER_PROACTIVE_ENABLED
    meta_proactive,     \* BOOLEAN: per-keeper meta.proactive.enabled
    decision            \* {"NONE","RUN_REACTIVE","RUN_PROACTIVE","SKIP"}

vars == << reactive_trigger, global_proactive, meta_proactive, decision >>

Decisions == {"NONE", "RUN_REACTIVE", "RUN_PROACTIVE", "SKIP"}

TypeOK ==
    /\ reactive_trigger \in BOOLEAN
    /\ global_proactive \in BOOLEAN
    /\ meta_proactive \in BOOLEAN
    /\ decision \in Decisions

\* Init: the environment picks any combination of gate/trigger values;
\* the decision starts unresolved.
Init ==
    /\ reactive_trigger \in BOOLEAN
    /\ global_proactive \in BOOLEAN
    /\ meta_proactive \in BOOLEAN
    /\ decision = "NONE"

\* Clean decision: reactive priority, then proactive gated on BOTH switches.
Decide ==
    /\ decision = "NONE"
    /\ decision' =
         IF reactive_trigger THEN "RUN_REACTIVE"
         ELSE IF global_proactive /\ meta_proactive THEN "RUN_PROACTIVE"
         ELSE "SKIP"
    /\ UNCHANGED << reactive_trigger, global_proactive, meta_proactive >>

\* Buggy decision: the pre-fix short-circuit. The global switch is not part
\* of the proactive gate, so proactive runs whenever the per-keeper flag is
\* on, silently ignoring the operator's global kill-switch.
DecideBuggy ==
    /\ decision = "NONE"
    /\ decision' =
         IF reactive_trigger THEN "RUN_REACTIVE"
         ELSE IF meta_proactive THEN "RUN_PROACTIVE"
         ELSE "SKIP"
    /\ UNCHANGED << reactive_trigger, global_proactive, meta_proactive >>

\* Once decided, stutter (bounded: the state space is the finite input domain).
Terminal ==
    /\ decision # "NONE"
    /\ UNCHANGED vars

Next == Decide \/ Terminal
NextBuggy == DecideBuggy \/ Terminal

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* Safety: a proactive turn implies BOTH the global and per-keeper gates were
\* enabled. Clean holds; Buggy violates it when global = FALSE, meta = TRUE.
Safety ==
    (decision = "RUN_PROACTIVE") => (global_proactive /\ meta_proactive)
====
