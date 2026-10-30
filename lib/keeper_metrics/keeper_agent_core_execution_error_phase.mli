(** Keeper_agent_core_execution_error_phase — closed sum for the [phase] label on
    [metric_keeper_agent_core_execution_errors].

    Each phase has one producer: [keeper_unified_turn] ([Cycle_failed]),
    [keeper_unified_turn_execution] ([Provider_context_overflow]) and
    [keeper_unified_turn_terminal_error] ([Runtime_exhausted],
    [Terminal_non_exhaustion]). [to_label] is exhaustive, so a new phase
    is a single edit here. *)

type t =
  | Runtime_exhausted
  | Terminal_non_exhaustion
  | Cycle_failed
  | Provider_context_overflow

val to_label : t -> string
