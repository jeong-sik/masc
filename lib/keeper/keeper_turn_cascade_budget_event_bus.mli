(** Turn event-bus summary record + helpers. *)

type turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_compaction = {
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;
  phase_hint : string;
}

type turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
  overflow_imminent : turn_event_bus_overflow option;
  context_compact_started_count : int;
  context_compacted_count : int;
  last_compaction : turn_event_bus_compaction option;
}

val empty_turn_event_bus_summary : turn_event_bus_summary

val merge_turn_event_bus_summary
  :  turn_event_bus_summary
  -> turn_event_bus_summary
  -> turn_event_bus_summary
<<<<<<< HEAD

val add_payload_kind : string list -> string -> string list
||||||| parent of 7671e4309c (fix: repair broken build from recent refactoring PRs)
=======

val add_payload_kind : string list -> string -> string list

val merge_payload_kinds : string list -> string list -> string list
>>>>>>> 7671e4309c (fix: repair broken build from recent refactoring PRs)
