---- MODULE AgentCancellation ----
(* Models Runtime.phase's Cancelled state and Eio.Cancel.Cancelled reraise
   behaviour across the OAS codebase.

   Runtime.phase alphabet (8 states):
     Bootstrapping, Running, Input_required, Waiting_on_workers, Finalizing,
     Completed, Failed, Cancelled

   Cancellation propagation contract (lib/eval_baseline.ml:80,
   lib/fs_atomic_eio.ml:74, lib/autonomy_exec.ml:236,323,
   lib/fs_result.ml multi-site):
   - Eio.Cancel.Cancelled caught at boundary layer
   - Must be re-raised (raise e) to propagate up the fiber tree
   - autonomy_exec.ml:447 maps caught Cancelled to `Cancelled result_status

   This spec verifies:
   1. CancelledNeverAbsorbed: Cancelled is never silently swallowed
   2. CancelledRequiresSignal: phase=Cancelled implies a cancel happened
   3. CancelledIsTerminal: once Cancelled, phase stays terminal
*)

EXTENDS Naturals

CONSTANTS
    MaxCancels   (* Bound on cancellation events *)

VARIABLES
    phase,        (* Runtime.phase value *)
    prev_phase,   (* Previous phase for transition validation *)
    cancel_count, (* Number of cancel signals observed *)
    absorbed      (* BUG: true when Cancelled is silently swallowed *)

vars == <<phase, prev_phase, cancel_count, absorbed>>

Phases == {"Bootstrapping", "Running", "Input_required", "Waiting_on_workers",
           "Finalizing", "Completed", "Failed", "Cancelled"}

NonTerminal == {"Bootstrapping", "Running", "Input_required",
                "Waiting_on_workers", "Finalizing"}
Terminal == {"Completed", "Failed", "Cancelled"}

(* ── Type invariant ─────────────────────────────────────── *)

TypeOK ==
    /\ phase \in Phases
    /\ prev_phase \in Phases
    /\ cancel_count \in Nat
    /\ absorbed \in BOOLEAN

(* ── Init ──────────────────────────────────────────────── *)

Init ==
    /\ phase = "Bootstrapping"
    /\ prev_phase = "Bootstrapping"
    /\ cancel_count = 0
    /\ absorbed = FALSE

(* ── Normal lifecycle transitions (simplified Runtime FSM) ── *)

TransitionTo(p) ==
    /\ prev_phase' = phase
    /\ phase' = p
    /\ UNCHANGED <<cancel_count, absorbed>>

NormalBootstrapping ==
    /\ phase = "Bootstrapping"
    /\ TransitionTo("Running")

NormalRunningToInput ==
    /\ phase = "Running"
    /\ TransitionTo("Input_required")

NormalInputRequired ==
    /\ phase = "Input_required"
    /\ TransitionTo("Running")

NormalRunningToWorkers ==
    /\ phase = "Running"
    /\ TransitionTo("Waiting_on_workers")

NormalWaiting ==
    /\ phase = "Waiting_on_workers"
    /\ TransitionTo("Finalizing")

NormalFinalizing ==
    /\ phase = "Finalizing"
    /\ TransitionTo("Completed")

NormalTransition ==
    /\ ~absorbed
    /\ (NormalBootstrapping
        \/ NormalRunningToInput
        \/ NormalInputRequired
        \/ NormalRunningToWorkers
        \/ NormalWaiting
        \/ NormalFinalizing)

(* ── Cancellation actions ───────────────────────────────── *)

(* Cancel signal arrives while agent is actively executing. *)
CancelSignal ==
    /\ ~absorbed
    /\ phase \in {"Running", "Waiting_on_workers"}
    /\ cancel_count < MaxCancels
    /\ cancel_count' = cancel_count + 1
    /\ prev_phase' = phase
    /\ phase' = "Cancelled"
    /\ absorbed' = FALSE

(* Correct behaviour: propagate Cancelled as terminal failure.
   autonomy_exec.ml:236,323 and fs_result.ml reraise sites. *)
PropagateCancelled ==
    /\ ~absorbed
    /\ phase = "Cancelled"
    /\ prev_phase' = phase
    /\ phase' \in {"Failed", "Completed"}
    /\ UNCHANGED <<cancel_count, absorbed>>

(* BUG: catch-and-swallow — a reraise site silently drops Cancelled.
   eval_baseline.ml:80 pattern matches `as e -> raise e` but a bug
   variant could omit the raise. autonomy_exec.ml:447 maps to
   `Cancelled but a downstream handler could ignore it. *)
BugAbsorbCancelled ==
    /\ phase = "Cancelled"
    /\ absorbed' = TRUE
    /\ prev_phase' = phase
    /\ phase' = "Running"
    /\ UNCHANGED cancel_count

(* After bug absorption, the agent continues as if uncancelled. *)
BugContinue ==
    /\ absorbed
    /\ phase \in NonTerminal
    /\ TransitionTo("Finalizing")

(* ── Next ──────────────────────────────────────────────── *)

Next ==
    \/ NormalTransition
    \/ CancelSignal
    \/ PropagateCancelled

(* Buggy spec adds catch-and-swallow action to clean Next.
   Safety invariant I1 MUST be violated to prove the model is valid. *)
NextBuggy ==
    \/ Next
    \/ BugAbsorbCancelled
    \/ BugContinue

(* ── Safety invariants ─────────────────────────────────── *)

(* I1: Cancelled must never be silently absorbed.
   If absorbed=TRUE, the invariant is violated. *)
CancelledNeverAbsorbed == ~absorbed

(* I2: Reaching Cancelled requires at least one cancel signal. *)
CancelledRequiresSignal ==
    (phase = "Cancelled") => (cancel_count > 0)

(* I3: Terminal phases (Completed, Failed, Cancelled) never transition
   to non-terminal phases. *)
TerminalIsStable ==
    (prev_phase \in Terminal /\ phase # prev_phase) => (phase \in Terminal)

(* ── Specifications ────────────────────────────────────── *)

Spec == Init /\ [][Next]_vars

SpecBuggy == Init /\ [][NextBuggy]_vars

====
