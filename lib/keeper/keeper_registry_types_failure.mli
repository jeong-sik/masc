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
  | Provider_runtime_error of { code : string; detail : string;
      provider_id : string option; http_status : int option;
      runtime_id : string option;
      agent_core_timeout : Keeper_turn_terminal_code.agent_core_timeout option;
      reason : Keeper_meta_contract.runtime_exhaustion_reason option;
      fenced_empty_turn_runtime : string option;
      (** Runtime id of a fenced provider attempt whose cause is the typed
          empty assistant turn
          ([Keeper_internal_error.fenced_cause_empty_no_progress = [Some true]]).
          [Some] only on the fenced-empty-turn construction path
          ([keeper_unified_turn_types.registry_failure_reason_of_internal_error]).
          Lets the status bridge lead with the operator's next action
          without re-parsing [detail]. [None] for every other
          provider/runtime error, including fenced failures whose cause is
          not an empty turn. *)
    }
  | Turn_configuration_error of { code : string; field : string option;
      detail : string; }
  | Official_client_recovery_required of Keeper_internal_error.official_client_recovery
  | Fiber_unresolved of fiber_drop_cause
  | Exception of string
  | Operator_interrupt
val failure_reason_to_string : failure_reason -> string
