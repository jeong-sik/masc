(** Metric_emit_dropped_site — closed sum for [site] label on
    [metric_keeper_metric_emit_dropped]. *)

type t =
  | Keeper_unified_turn
  | Cost_event_write (** Cost event write failure inside keeper_hooks_oas.ml. *)

val to_label : t -> string
