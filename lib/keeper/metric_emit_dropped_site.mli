(** Metric_emit_dropped_site — closed sum for [site] label on
    [metric_keeper_metric_emit_dropped]. *)

type t = Keeper_unified_turn

val to_label : t -> string
