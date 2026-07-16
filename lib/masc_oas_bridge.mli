(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces cancellation safety and typed exception isolation without owning
    an execution budget. *)

type caller =
  | Anti_rationalization
  | Operator_judge

(** Stable observation label for the closed caller vocabulary. *)
val caller_key : caller -> string

(** Run a generic OAS operation without imposing a MASC wall-clock budget.
    A genuine inner [Eio.Time.Timeout] becomes a typed SDK timeout;
    [Eio.Cancel.Cancelled] is always re-raised with its backtrace. When the
    current domain has a captured Eio clock, elapsed wall time is observed;
    clock absence never refuses execution. *)
val run_safe
  :  caller:caller
  -> (unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
