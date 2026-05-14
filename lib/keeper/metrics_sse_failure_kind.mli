(** Metrics_sse_failure_kind — closed sum for the [kind] label on
    [metric_keeper_metrics_sse_failures].

    Replaces 2 hardcoded string literals in [keeper_unified_metrics.ml]
    (`"compaction"` / `"handoff"`) — the two SSE broadcast paths
    whose failures are counted on this metric. *)

type t =
  | Compaction (** keeper_compaction lifecycle SSE broadcast failure. *)
  | Handoff (** keeper handoff/rollover SSE broadcast failure. *)

val to_label : t -> string
