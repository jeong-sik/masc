(** Closed sum for the [kind] label on
    [metric_keeper_metrics_sse_failures]. *)

type t =
  | Compaction
  | Handoff

val to_label : t -> string
