(** Oas_execution_error_phase — closed sum for the [phase] label on
    two keeper-side metrics:

    - [metric_keeper_oas_execution_errors] (7 phases from
      [keeper_unified_turn], [keeper_turn_cascade_budget],
      [keeper_post_turn])
    - [metric_keeper_write_meta_failures] ([turn_start])

    Replaces 8 hardcoded string literals scattered across 3 files.
    The compiler enforces exhaustive coverage in [to_label] (a missing
    constructor is a compile error there) so adding a new phase
    requires a single edit here and the new wire string surfaces
    immediately. *)

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
