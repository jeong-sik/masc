(** Runtime manifest scan state and reader for keeper runtime-trace responses.

    Split from {!Server_dashboard_http_keeper_api}; included back there so
    existing local call sites keep using the same names. *)

open Server_dashboard_http_keeper_api_types

type manifest_scan_diagnostic =
  | Retired_event_row of Keeper_runtime_manifest.retired_event_kind
  | Unsupported_event_row of string
  | Invalid_manifest_row of string
  | Invalid_json_row of string

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
  ; retired_event_counts : (Keeper_runtime_manifest.retired_event_kind, int) Hashtbl.t
  ; unsupported_event_counts : (string, int) Hashtbl.t
  ; mutable unsupported_event_count : int
  ; mutable unsupported_event_unattributed_count : int
  ; mutable invalid_manifest_row_count : int
  ; mutable invalid_json_row_count : int
  ; diagnostic_samples : manifest_scan_diagnostic Queue.t
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
  ; retired_event_counts = Hashtbl.create 7
  ; unsupported_event_counts = Hashtbl.create 7
  ; unsupported_event_count = 0
  ; unsupported_event_unattributed_count = 0
  ; invalid_manifest_row_count = 0
  ; invalid_json_row_count = 0
  ; diagnostic_samples = Queue.create ()
  }

let push_bounded queue limit value =
  if limit > 0 then (
    Queue.push value queue;
    if Queue.length queue > limit then ignore (Queue.pop queue))

let queue_to_list queue =
  let values = ref [] in
  Queue.iter (fun value -> values := value :: !values) queue;
  List.rev !values

let increment_count table key =
  let current =
    match Hashtbl.find_opt table key with
    | Some count -> count
    | None -> 0
  in
  Hashtbl.replace table key (current + 1)
;;

let increment_bounded_count table ~capacity key =
  match Hashtbl.find_opt table key with
  | Some current ->
    Hashtbl.replace table key (current + 1);
    true
  | None when Hashtbl.length table < capacity ->
    Hashtbl.add table key 1;
    true
  | None -> false
;;

let record_manifest_scan_diagnostic scan diagnostic =
  (match diagnostic with
   | Retired_event_row event -> increment_count scan.retired_event_counts event
   | Unsupported_event_row event ->
     scan.unsupported_event_count <- scan.unsupported_event_count + 1;
     if not (increment_bounded_count scan.unsupported_event_counts ~capacity:scan.limit event)
     then
       scan.unsupported_event_unattributed_count <-
         scan.unsupported_event_unattributed_count + 1
   | Invalid_manifest_row _ ->
     scan.invalid_manifest_row_count <- scan.invalid_manifest_row_count + 1
   | Invalid_json_row _ -> scan.invalid_json_row_count <- scan.invalid_json_row_count + 1);
  push_bounded scan.diagnostic_samples scan.limit diagnostic
;;

let sorted_count_rows table key_to_string =
  Hashtbl.fold
    (fun key count rows -> (key_to_string key, count) :: rows)
    table
    []
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map (fun (event, count) ->
    `Assoc [ "event", `String event; "count", `Int count ])
;;

let count_total table = Hashtbl.fold (fun _ count total -> total + count) table 0

let manifest_scan_diagnostic_to_json = function
  | Retired_event_row event ->
    `Assoc
      [ "kind", `String "retired_event"
      ; "event", `String (Keeper_runtime_manifest.retired_event_kind_to_string event)
      ]
  | Unsupported_event_row event ->
    `Assoc [ "kind", `String "unsupported_event"; "event", `String event ]
  | Invalid_manifest_row detail ->
    `Assoc [ "kind", `String "invalid_manifest_row"; "detail", `String detail ]
  | Invalid_json_row detail ->
    `Assoc [ "kind", `String "invalid_json_row"; "detail", `String detail ]
;;

let runtime_manifest_scan_diagnostics_schema =
  "keeper.runtime_manifest_scan_diagnostics.v1"
;;

let runtime_manifest_scan_diagnostics_json scan =
  `Assoc
    [ "schema", `String runtime_manifest_scan_diagnostics_schema
    ; "retired_event_count", `Int (count_total scan.retired_event_counts)
    ; ( "retired_event_counts"
      , `List
          (sorted_count_rows
             scan.retired_event_counts
             Keeper_runtime_manifest.retired_event_kind_to_string) )
    ; "unsupported_event_count", `Int scan.unsupported_event_count
    ; ( "unsupported_event_counts"
      , `List (sorted_count_rows scan.unsupported_event_counts Fun.id) )
    ; ( "unsupported_event_unattributed_count"
      , `Int scan.unsupported_event_unattributed_count )
    ; "invalid_manifest_row_count", `Int scan.invalid_manifest_row_count
    ; "invalid_json_row_count", `Int scan.invalid_json_row_count
    ; ( "samples"
      , `List
          (List.map
             manifest_scan_diagnostic_to_json
             (queue_to_list scan.diagnostic_samples)) )
    ]
;;

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

let update_runtime_manifest_scan scan (row : Keeper_runtime_manifest.t) =
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
      | None -> ())
   | Keeper_runtime_manifest.Provider_attempt_started ->
     scan.provider_started_count <- scan.provider_started_count + 1;
     push_bounded scan.provider_attempt_rows scan.limit row
   | Keeper_runtime_manifest.Provider_attempt_finished ->
     scan.provider_finished_count <- scan.provider_finished_count + 1;
     scan.provider_terminal_row <- Some row;
     push_bounded scan.provider_attempt_rows scan.limit row
   | _ -> ())

let manifest_identity_matches ?turn_id keeper_name trace_id
    (identity : Keeper_runtime_manifest.row_identity) =
  String.equal identity.keeper_name keeper_name
  && String.equal identity.trace_id trace_id
  &&
  match turn_id with
  | None -> true
  | Some wanted -> identity.keeper_turn_id = Some wanted
;;

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
            let json = Yojson.Safe.from_string line in
            match Keeper_runtime_manifest.decode_persisted_row json with
            | Ok (Keeper_runtime_manifest.Active_row row)
              when manifest_row_matches ?turn_id keeper_name trace_id row ->
              update_runtime_manifest_scan scan row
            | Ok (Keeper_runtime_manifest.Retired_row (identity, retired))
              when manifest_identity_matches ?turn_id keeper_name trace_id identity ->
              record_manifest_scan_diagnostic scan (Retired_event_row retired)
            | Ok (Keeper_runtime_manifest.Unsupported_row (identity, unsupported))
              when manifest_identity_matches ?turn_id keeper_name trace_id identity ->
              record_manifest_scan_diagnostic scan (Unsupported_event_row unsupported)
            | Ok _ -> ()
            | Error detail ->
              record_manifest_scan_diagnostic scan (Invalid_manifest_row detail)
          with
          | Yojson.Json_error msg | Yojson.Safe.Util.Type_error (msg, _) ->
            record_manifest_scan_diagnostic scan (Invalid_json_row msg));
  scan
