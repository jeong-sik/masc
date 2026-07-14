(** Turn event-bus observation summary. Compaction lifecycle belongs to
    MASC durable lane state, not the lossy OAS observation bus. *)

type turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary
  :  turn_event_bus_summary
  -> turn_event_bus_summary
  -> turn_event_bus_summary

val add_payload_kind : string list -> string -> string list

val merge_payload_kinds : string list -> string list -> string list
