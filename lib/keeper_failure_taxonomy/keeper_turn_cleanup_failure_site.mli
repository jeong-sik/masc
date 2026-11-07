(** Keeper_turn_cleanup_failure_site — closed sum for [site] label on
    [masc_keeper_turn_cleanup_failures_total] (2 sites in
    keeper_unified_turn.ml). *)

type t =
  | Unsubscribe_event_bus
  | Mark_turn_finished

val to_label : t -> string
