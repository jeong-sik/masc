(** Cascade_sync_failure_site — closed sum for [site] label on
    [metric_keeper_cascade_sync_failures] (2 sites in
    keeper_turn_cascade_budget.ml). *)

type t =
  | Resume_sync
  | Pause_sync

val to_label : t -> string
