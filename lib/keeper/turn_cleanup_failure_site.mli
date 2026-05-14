(** Turn_cleanup_failure_site — closed sum for [site] label on
    [metric_keeper_turn_cleanup_failures] (2 sites in
    keeper_unified_turn.ml). *)

type t =
  | Unsubscribe_event_bus
  | Mark_turn_finished

val to_label : t -> string
