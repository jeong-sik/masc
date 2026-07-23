(** Turn event-bus observation summary.

    OAS lifecycle events supply correlation metadata only. MASC-owned
    compaction state must come from the lane's durable completion path,
    never from this lossy observation bus. *)

type turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

let empty_turn_event_bus_summary =
  {
    correlation_id = None;
    run_id = None;
    caused_by = None;
    event_count = 0;
    payload_kinds = [];
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
  }
