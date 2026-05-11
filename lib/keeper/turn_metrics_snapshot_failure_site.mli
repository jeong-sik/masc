(** Turn_metrics_snapshot_failure_site — closed sum for [site] label on
    [metric_keeper_turn_metrics_snapshot_failures]. *)

type t = Post_cycle

val to_label : t -> string
