(** Turn event-bus summary record + helpers.

    Captures the within-turn observations emitted by
    [Agent_sdk.Event_bus] — correlation/run identifiers, observed
    overflow-imminent events, and context-compaction counters —
    rolled up into a single [turn_event_bus_summary] record that the
    keeper's post-turn handler attaches to the receipt.

    Pure data + a left-biased merge (left wins on the
    string-id and overflow_imminent slots; right wins on
    last_compaction; counters sum). Verbatim extract from
    [Keeper_turn_runtime_budget]; the parent retains transparent
    record aliases + 2 value aliases. *)

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

let empty_turn_event_bus_summary =
  {
    correlation_id = None;
    run_id = None;
    caused_by = None;
    event_count = 0;
    payload_kinds = [];
    overflow_imminent = None;
    context_compact_started_count = 0;
    context_compacted_count = 0;
    last_compaction = None;
  }

let add_payload_kind kinds kind =
  if List.mem kind kinds then kinds else kinds @ [ kind ]

let merge_payload_kinds left right =
  List.fold_left add_payload_kind left right

let merge_turn_event_bus_summary
    (left : turn_event_bus_summary)
    (right : turn_event_bus_summary) : turn_event_bus_summary =
  {
    correlation_id =
      (match left.correlation_id with
       | Some _ -> left.correlation_id
       | None -> right.correlation_id);
    run_id =
      (match left.run_id with
       | Some _ -> left.run_id
       | None -> right.run_id);
    caused_by =
      (match left.caused_by with
       | Some _ -> left.caused_by
       | None -> right.caused_by);
    event_count = left.event_count + right.event_count;
    payload_kinds = merge_payload_kinds left.payload_kinds right.payload_kinds;
    overflow_imminent =
      (match right.overflow_imminent with
       | Some _ -> right.overflow_imminent
       | None -> left.overflow_imminent);
    context_compact_started_count =
      left.context_compact_started_count + right.context_compact_started_count;
    context_compacted_count =
      left.context_compacted_count + right.context_compacted_count;
    last_compaction =
      (match right.last_compaction with
       | Some _ -> right.last_compaction
       | None -> left.last_compaction);
  }
