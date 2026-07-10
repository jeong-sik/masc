(** Runtime manifest scan state and reader for keeper runtime-trace responses.

    Split from {!Server_dashboard_http_keeper_api}; included back there so
    existing local call sites keep using the same names. *)

open Server_dashboard_http_keeper_api_types

type runtime_manifest_scan =
  { path : string
  ; limit : int
  ; returned_rows : Keeper_runtime_manifest.t Queue.t
  ; provider_attempt_rows : Keeper_runtime_manifest.t Queue.t
  ; event_counts : (string, int) Hashtbl.t
  ; mutable total_rows : int
  ; mutable has_terminal : bool
  ; mutable terminal_keeper_turn_ids : int list
  ; mutable max_oas_turn_count : int option
  ; mutable keeper_turn_ids : int list
  ; mutable event_bus_count : int
  ; mutable event_bus_correlation_ids : string list
  ; mutable event_bus_run_ids : string list
  ; mutable context_compact_started_count : int
  ; mutable context_compacted_count : int
  ; mutable last_compaction : Yojson.Safe.t option
  ; mutable latest_provider_lane_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_row : Keeper_runtime_manifest.t option
  ; mutable latest_pre_dispatch_blocked_row : Keeper_runtime_manifest.t option
  ; mutable payload_role_counts : (string, int) Hashtbl.t
  ; mutable source_clock_counts : (string, int) Hashtbl.t
  ; mutable context_injected_count : int
  ; mutable context_compacted_event_count : int
  ; mutable provider_started_count : int
  ; mutable provider_finished_count : int
  ; mutable provider_terminal_row : Keeper_runtime_manifest.t option
  ; mutable latest_context_injected_row : Keeper_runtime_manifest.t option
  ; mutable latest_context_compacted_row : Keeper_runtime_manifest.t option
  ; mutable dag_edges : (string * string) list
  ; mutable scanned_lines : int
  ; scan_line_limit : int
  ; scan_scope : string
  }

let runtime_manifest_tail_scan_min_lines = 1000
let runtime_manifest_tail_scan_max_lines = 6000
let runtime_manifest_tail_scan_multiplier = 24

let runtime_manifest_tail_scan_line_limit ~limit =
  max
    runtime_manifest_tail_scan_min_lines
    (min
       runtime_manifest_tail_scan_max_lines
       (limit * runtime_manifest_tail_scan_multiplier))
;;

let make_runtime_manifest_scan ~path ~limit ~scan_line_limit ~scan_scope =
  { path
  ; limit
  ; returned_rows = Queue.create ()
  ; provider_attempt_rows = Queue.create ()
  ; event_counts = Hashtbl.create 17
  ; total_rows = 0
  ; has_terminal = false
  ; terminal_keeper_turn_ids = []
  ; max_oas_turn_count = None
  ; keeper_turn_ids = []
  ; event_bus_count = 0
  ; event_bus_correlation_ids = []
  ; event_bus_run_ids = []
  ; context_compact_started_count = 0
  ; context_compacted_count = 0
  ; last_compaction = None
  ; latest_provider_lane_decision = None
  ; latest_provider_lane_row = None
  ; latest_pre_dispatch_blocked_row = None
  ; payload_role_counts = Hashtbl.create 17
  ; source_clock_counts = Hashtbl.create 17
  ; context_injected_count = 0
  ; context_compacted_event_count = 0
  ; provider_started_count = 0
  ; provider_finished_count = 0
  ; provider_terminal_row = None
  ; latest_context_injected_row = None
  ; latest_context_compacted_row = None
  ; dag_edges = []
  ; scanned_lines = 0
  ; scan_line_limit
  ; scan_scope
  }

let push_bounded queue limit value =
  if limit > 0 then (
    Queue.push value queue;
    if Queue.length queue > limit then ignore (Queue.pop queue))

let queue_to_list queue =
  let values = ref [] in
  Queue.iter (fun value -> values := value :: !values) queue;
  List.rev !values

let increment_event_count scan event =
  let key = Keeper_runtime_manifest.event_kind_to_string event in
  let current = Option.value (Hashtbl.find_opt scan.event_counts key) ~default:0 in
  Hashtbl.replace scan.event_counts key (current + 1)

let runtime_manifest_scan_event_count scan event =
  let key = Keeper_runtime_manifest.event_kind_to_string event in
  Option.value (Hashtbl.find_opt scan.event_counts key) ~default:0

let max_int_opt current value =
  match current with
  | None -> Some value
  | Some existing -> Some (max existing value)

let update_runtime_manifest_scan scan row =
  scan.total_rows <- scan.total_rows + 1;
  push_bounded scan.returned_rows scan.limit row;
  increment_event_count scan row.Keeper_runtime_manifest.event;
  (match
     let decision = row.Keeper_runtime_manifest.decision in
     let clock_refs = Json_util.assoc_member_opt "clock_refs" decision in
     match clock_refs with
     | Some (`Assoc _ as refs) ->
       let event_id = Json_util.get_string refs "event_id" in
       let parent_event_id = Json_util.get_string refs "parent_event_id" in
       (match event_id, parent_event_id with
        | Some eid, Some peid -> Some (peid, eid)
        | _ -> None)
     | None | Some _ -> None
   with
   | Some edge -> scan.dag_edges <- edge :: scan.dag_edges
   | None -> ());
  (match
     Json_util.assoc_member_opt "payload_role" row.Keeper_runtime_manifest.decision
   with
   | Some (`String role) ->
     let current =
       match Hashtbl.find_opt scan.payload_role_counts role with
       | Some value -> value
       | None -> 0
     in
     Hashtbl.replace scan.payload_role_counts role (current + 1)
   | _ -> ());
  let source_clock =
    let fallback =
      row.Keeper_runtime_manifest.event
      |> Keeper_runtime_manifest.source_clock_of_event
      |> Keeper_runtime_manifest.source_clock_to_string
    in
    let clock_refs =
      Json_util.assoc_member_opt "clock_refs" row.Keeper_runtime_manifest.decision
    in
    match clock_refs with
    | Some (`Assoc _ as refs) ->
      (match Json_util.get_string refs "source_clock" with
       | Some clock -> (
         match Keeper_runtime_manifest.source_clock_of_string clock with
         | Some valid -> Keeper_runtime_manifest.source_clock_to_string valid
         | None -> fallback)
       | None -> fallback)
    | _ -> fallback
  in
  let current =
    match Hashtbl.find_opt scan.source_clock_counts source_clock with
    | Some value -> value
    | None -> 0
  in
  Hashtbl.replace scan.source_clock_counts source_clock (current + 1);
  (match row.Keeper_runtime_manifest.keeper_turn_id with
   | Some value -> scan.keeper_turn_ids <- value :: scan.keeper_turn_ids
   | None -> ());
  (match row.Keeper_runtime_manifest.oas_turn_count with
   | Some value -> scan.max_oas_turn_count <- max_int_opt scan.max_oas_turn_count value
   | None -> ());
  (match row.Keeper_runtime_manifest.event with
   | Keeper_runtime_manifest.Turn_finished ->
     scan.has_terminal <- true;
     (match row.Keeper_runtime_manifest.keeper_turn_id with
      | Some value ->
        scan.terminal_keeper_turn_ids <- value :: scan.terminal_keeper_turn_ids
      | None -> ())
   | Keeper_runtime_manifest.Provider_lane_resolved ->
     scan.latest_provider_lane_decision <- Some row.Keeper_runtime_manifest.decision;
     scan.latest_provider_lane_row <- Some row
   | Keeper_runtime_manifest.Pre_dispatch_blocked ->
     scan.latest_pre_dispatch_blocked_row <- Some row
   | Keeper_runtime_manifest.Context_injected ->
     scan.context_injected_count <- scan.context_injected_count + 1;
     scan.latest_context_injected_row <- Some row
   | Keeper_runtime_manifest.Context_compacted ->
     scan.context_compacted_event_count <- scan.context_compacted_event_count + 1;
     scan.latest_context_compacted_row <- Some row
   | Keeper_runtime_manifest.Event_bus_correlated ->
     let decision = row.Keeper_runtime_manifest.decision in
     scan.event_bus_count <- scan.event_bus_count + 1;
     (match Json_util.get_string decision "correlation_id" with
      | Some value -> scan.event_bus_correlation_ids <- value :: scan.event_bus_correlation_ids
      | None -> ());
     (match Json_util.get_string decision "run_id" with
      | Some value -> scan.event_bus_run_ids <- value :: scan.event_bus_run_ids
      | None -> ());
     scan.context_compact_started_count <-
       scan.context_compact_started_count
       + Option.value
           (Json_util.get_int decision "context_compact_started_count")
           ~default:0;
     scan.context_compacted_count <-
       scan.context_compacted_count
       + Option.value (Json_util.get_int decision "context_compacted_count")
           ~default:0;
     (match Json_util.assoc_member_opt "last_compaction" decision with
      | Some (`Assoc _ as obj) -> scan.last_compaction <- Some obj
      | _ -> ())
   | Keeper_runtime_manifest.Provider_attempt_started ->
     scan.provider_started_count <- scan.provider_started_count + 1;
     push_bounded scan.provider_attempt_rows scan.limit row
   | Keeper_runtime_manifest.Provider_attempt_finished ->
     scan.provider_finished_count <- scan.provider_finished_count + 1;
     scan.provider_terminal_row <- Some row;
     push_bounded scan.provider_attempt_rows scan.limit row
   | _ -> ())

let read_runtime_manifest_scan ~config ~keeper_name ~trace_id ?turn_id ~limit () =
  let path =
    Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id
  in
  let scan_line_limit = runtime_manifest_tail_scan_line_limit ~limit in
  let scan =
    make_runtime_manifest_scan
      ~path
      ~limit
      ~scan_line_limit
      ~scan_scope:"tail"
  in
  Dated_jsonl.load_tail_lines path ~max_lines:scan_line_limit
  |> List.iter
       (fun line ->
          scan.scanned_lines <- scan.scanned_lines + 1;
          try
            match Yojson.Safe.from_string line |> Keeper_runtime_manifest.of_json with
            | Ok row when manifest_row_matches ?turn_id keeper_name trace_id row ->
                update_runtime_manifest_scan scan row
            | Ok _ -> ()
            | Error msg ->
                Log.warn
                  ~ctx:"runtime_manifest_scan"
                  "Runtime manifest row skipped (keeper=%s trace=%s): %s"
                  keeper_name
                  trace_id
                  msg
          with
          | Yojson.Json_error msg | Yojson.Safe.Util.Type_error (msg, _) ->
              Log.warn
                ~ctx:"runtime_manifest_scan"
                "Runtime manifest row JSON parse failed (keeper=%s trace=%s): %s"
                keeper_name
                trace_id
                msg);
  scan
