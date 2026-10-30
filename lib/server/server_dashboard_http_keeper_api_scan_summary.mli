(** Runtime-manifest scan: receipt-matching + summary-JSON helpers.

    Pure helpers over [Server_dashboard_http_keeper_runtime_manifest_scan]
    state and JSONL receipt rows on disk. No side effects beyond
    reading the receipt files in {!read_receipt_rows}. *)

(** [read_receipt_rows ~keeper_name ~trace_id ?turn_id paths] reads
    every JSONL receipt under [paths] and returns the rows that match
    {!receipt_row_matches}. Result is in file order; subsequent
    [paths] are concatenated. *)
val read_receipt_rows
  :  keeper_name:string
  -> trace_id:string
  -> ?turn_id:int
  -> string list
  -> Yojson.Safe.t list

(** [unique_ints values] returns [values] in ascending order with
    duplicates removed. *)
val unique_ints : int list -> int list

(** [json_int_list values] wraps [values] as [`List] of [`Int]. *)
val json_int_list : int list -> Yojson.Safe.t

(** [event_bus_summary_json scan] folds the event-bus counters out of
    [scan] into a single [`Assoc] payload for the dashboard, carrying
    [event_bus_correlated_count], [correlation_ids] and [run_ids].
    Correlation IDs and run IDs are reversed and deduplicated
    (preserving first-seen order). *)
val event_bus_summary_json
  :  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan
  -> Yojson.Safe.t

(** [selected_keeper_turn_id ?turn_id scan] returns [Some n] when
    [turn_id = Some n], otherwise the maximum [keeper_turn_ids] in
    [scan] (or [None] when the list is empty). *)
val selected_keeper_turn_id
  :  ?turn_id:int
  -> Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan
  -> int option

(** [terminal_event_present_for_turn ?keeper_turn_id scan] returns
    [true] when the manifest scan saw a terminal event for the
    specified turn (or any terminal event when [keeper_turn_id] is
    [None]). *)
val terminal_event_present_for_turn
  :  ?keeper_turn_id:int
  -> Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan
  -> bool
