(** Keeper_turn_metrics_snapshot_failure_site — closed sum for [site] label on
    [masc_keeper_turn_metrics_snapshot_failures_total]. *)

type t = Post_cycle

val to_label : t -> string
