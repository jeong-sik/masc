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
  ; mutable memory_injected_count : int
  ; mutable memory_injected_present_count : int
  ; mutable memory_flushed_count : int
  ; mutable memory_flush_success_count : int
  ; mutable memory_flush_error_count : int
  ; mutable episodes_flushed : int
  ; mutable procedures_flushed : int
  ; mutable latest_tool_surface_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_row : Keeper_runtime_manifest.t option
  ; mutable latest_pre_dispatch_blocked_row : Keeper_runtime_manifest.t option
  ; mutable context_injected_count : int
  ; mutable context_compacted_event_count : int
  ; mutable provider_started_count : int
  ; mutable provider_finished_count : int
  ; mutable provider_terminal_row : Keeper_runtime_manifest.t option
  }

let make_runtime_manifest_scan ~path ~limit =
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
  ; memory_injected_count = 0
  ; memory_injected_present_count = 0
  ; memory_flushed_count = 0
  ; memory_flush_success_count = 0
  ; memory_flush_error_count = 0
  ; episodes_flushed = 0
  ; procedures_flushed = 0
  ; latest_tool_surface_decision = None
  ; latest_provider_lane_decision = None
  ; latest_provider_lane_row = None
  ; latest_pre_dispatch_blocked_row = None
  ; context_injected_count = 0
  ; context_compacted_event_count = 0
  ; provider_started_count = 0
  ; provider_finished_count = 0
  ; provider_terminal_row = None
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
   | Keeper_runtime_manifest.Tool_surface_selected ->
     scan.latest_tool_surface_decision <- Some row.Keeper_runtime_manifest.decision
   | Keeper_runtime_manifest.Provider_lane_resolved ->
     scan.latest_provider_lane_decision <- Some row.Keeper_runtime_manifest.decision;
     scan.latest_provider_lane_row <- Some row
   | Keeper_runtime_manifest.Pre_dispatch_blocked ->
     scan.latest_pre_dispatch_blocked_row <- Some row
   | Keeper_runtime_manifest.Context_injected ->
     scan.context_injected_count <- scan.context_injected_count + 1
   | Keeper_runtime_manifest.Context_compacted ->
     scan.context_compacted_event_count <- scan.context_compacted_event_count + 1
   | Keeper_runtime_manifest.Event_bus_correlated ->
     let decision = row.Keeper_runtime_manifest.decision in
     scan.event_bus_count <- scan.event_bus_count + 1;
     (match json_string_member_opt "correlation_id" decision with
      | Some value -> scan.event_bus_correlation_ids <- value :: scan.event_bus_correlation_ids
      | None -> ());
     (match json_string_member_opt "run_id" decision with
      | Some value -> scan.event_bus_run_ids <- value :: scan.event_bus_run_ids
      | None -> ());
     scan.context_compact_started_count <-
       scan.context_compact_started_count
       + Option.value
           (json_int_member_opt "context_compact_started_count" decision)
           ~default:0;
     scan.context_compacted_count <-
       scan.context_compacted_count
       + Option.value (json_int_member_opt "context_compacted_count" decision)
           ~default:0;
     (match Yojson.Safe.Util.member "last_compaction" decision with
      | `Assoc _ as obj -> scan.last_compaction <- Some obj
      | _ -> ())
   | Keeper_runtime_manifest.Memory_injected ->
     scan.memory_injected_count <- scan.memory_injected_count + 1;
     if String.equal row.Keeper_runtime_manifest.status "injected"
     then scan.memory_injected_present_count <- scan.memory_injected_present_count + 1
   | Keeper_runtime_manifest.Memory_flushed ->
     let decision = row.Keeper_runtime_manifest.decision in
     scan.memory_flushed_count <- scan.memory_flushed_count + 1;
     if String.equal row.Keeper_runtime_manifest.status "success"
     then scan.memory_flush_success_count <- scan.memory_flush_success_count + 1;
     if String.equal row.Keeper_runtime_manifest.status "error"
     then scan.memory_flush_error_count <- scan.memory_flush_error_count + 1;
     scan.episodes_flushed <-
       scan.episodes_flushed
       + Option.value (json_int_member_opt "episodes_flushed" decision) ~default:0;
     scan.procedures_flushed <-
       scan.procedures_flushed
       + Option.value (json_int_member_opt "procedures_flushed" decision) ~default:0
   | Keeper_runtime_manifest.Provider_attempt_started ->
     scan.provider_started_count <- scan.provider_started_count + 1;
     push_bounded scan.provider_attempt_rows scan.limit row
   | Keeper_runtime_manifest.Provider_attempt_finished ->
     scan.provider_finished_count <- scan.provider_finished_count + 1;
     scan.provider_terminal_row <- Some row;
     push_bounded scan.provider_attempt_rows scan.limit row
   | _ -> ())

let read_runtime_manifest_scan ~config ~keeper_name ~trace_id ?turn_id ~limit ()
  =
  let path =
    Keeper_runtime_manifest.path_for_trace config ~keeper_name ~trace_id
  in
  let scan = make_runtime_manifest_scan ~path ~limit in
  Fs_compat.fold_jsonl_lines
    ~init:()
    ~f:(fun () ~line_no:_ json ->
      match Keeper_runtime_manifest.of_json json with
      | Ok row when manifest_row_matches ?turn_id keeper_name trace_id row ->
          update_runtime_manifest_scan scan row
      | Ok _ | Error _ -> ())
    path;
  scan
