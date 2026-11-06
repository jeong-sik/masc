(** Keeper_metric_emit_dropped_site — closed sum for [site] label on
    [masc_keeper_metric_emit_dropped_total]. *)

type t =
  | Keeper_unified_turn
  | Cost_event_write (** Cost event write failure inside keeper_hooks_agent_core.ml. *)

val to_label : t -> string
