(** Issue #18901: Cause carried inside [Fiber_unresolved] so the emit
    site is forced to distinguish graceful shutdown races from real
    missed-resolution bugs. *)
type fiber_drop_cause =
  | Graceful_shutdown
  | Cancelled_by_parent
  | Unexpected
type failure_reason =
    Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Stale_termination_storm of { count : int; }
  | Provider_runtime_error of { code : string; detail : string;
      provider_id : string option; http_status : int option;
      runtime_id : string option;
      agent_core_timeout : Keeper_turn_terminal_code.agent_core_timeout option;
      reason : Keeper_meta_contract.runtime_exhaustion_reason option;
    }
  | Turn_configuration_error of { code : string; field : string option;
      detail : string; }
  | Fiber_unresolved of fiber_drop_cause
  | Exception of string
  | Turn_overflow_failure
  | Operator_interrupt
val failure_reason_to_string : failure_reason -> string
