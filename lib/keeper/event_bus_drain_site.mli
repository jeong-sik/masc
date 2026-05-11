(** Event_bus_drain_site — closed sum for [site] label on
    [metric_keeper_event_bus_drain].  Currently a single-variant sum
    capturing the only emit site in keeper_unified_turn.ml; closing
    the type here so a future emit-site addition surfaces at compile
    time. *)

type t = Background_poll

val to_label : t -> string
