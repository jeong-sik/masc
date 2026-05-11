(** Oas_execution_error_phase — closed sum for the [phase] label on
    [metric_keeper_oas_execution_errors].

    Replaces the prior pattern of 8 hardcoded string literals scattered
    across [keeper_unified_turn.ml], [keeper_turn_cascade_budget.ml],
    and [keeper_post_turn.ml].  Centralises the closed set so adding a
    new phase requires a single edit here and the compiler enforces
    exhaustive coverage at every emission site. *)

type t =
  | Turn_start
  | Cascade_exhausted
  | Terminal_non_exhaustion
  | Recoverable_cascade_transient
  | Cycle_failed
  | Persistent_escalation
  | Resilience_audit_store
  | Overflow_retry_oas_load

val to_label : t -> string
