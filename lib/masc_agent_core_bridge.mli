(* lib/masc_agent_core_bridge.mli *)

(** Centralized boundary between MASC subsystems and agent core.
    Enforces cancellation safety and typed exception isolation without owning
    an execution budget. *)

type caller =
  | Anti_rationalization
  | Fusion_judge
  | Fusion_panel

(** Run a generic AGENT_CORE operation without imposing a MASC wall-clock budget.
    A genuine inner [Eio.Time.Timeout] becomes a typed agent-core timeout;
    [Eio.Cancel.Cancelled] is always re-raised with its backtrace. When the
    current domain has a captured Eio clock, elapsed wall time is observed;
    clock absence never refuses execution. *)
val run_safe
  :  caller:caller
  -> (unit -> ('a, Agent_core.Error.t) result)
  -> ('a, Agent_core.Error.t) result
