(** Runtime-lens clock-group projection and gap detection.

    Derives grouped clock edges (turns, batches, attempts, checkpoints,
    compactions, memory injections, event-bus correlations) from the edge
    stream produced by {!Server_dashboard_http_keeper_runtime_lens_clock_edges}. *)

open Server_dashboard_http_keeper_api_types
open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let json_string_opt = Json_util.string_opt_to_json

let json_int_opt = Json_util.int_opt_to_json

let edge_string key edge = json_string_member_opt key edge
let edge_int key edge = json_int_member_opt key edge
let edge_string_list key edge = json_string_list_member key edge

let add_unique value values =
  if List.mem value values then values else values @ [ value ]

let add_unique_non_empty value values =
  let value = String.trim value in
  if value = "" then values else add_unique value values

let option_string_default default = function
  | Some value when String.trim value <> "" -> value
  | Some _ | None -> default

let option_int_string = function
  | Some value -> string_of_int value
  | None -> "unknown"

type clock_group_acc =
  { group_type : string
  ; group_id : string
  ; mutable edge_count : int
  ; mutable edge_ids : string list
  ; mutable lanes : string list
  ; mutable events : string list
  ; mutable statuses : string list
  ; mutable first_observed_at : string option
  ; mutable last_observed_at : string option
  ; mutable terminal_events : string list
  ; mutable parent_event_ids : string list
  ; mutable caused_by : string list
  ; mutable event_bus_event_count : int
  ; mutable event_bus_payload_kinds : string list
  }

let clock_group_terminal_event group_type event =
  match group_type, event with
  | "turn", ("turn_finished" | "pre_dispatch_blocked") -> true
  | "provider_attempt", "provider_attempt_finished" -> true
  | "tool_batch", "provider_lane_resolved" -> true
  | ( "checkpoint",
      ("checkpoint_saved" | "state_snapshot_sidecar_saved" | "working_state_sidecar_saved") )
    ->
    true
  | "memory_injection", "memory_flushed" -> true
  | "compaction", ("context_compacted" | "event_bus_correlated") -> true
  | "event_bus_correlation", "event_bus_correlated" -> true
  | _ -> false

let clock_group_key group_type group_id = group_type ^ "\000" ^ group_id

let runtime_lens_clock_groups_json scan =
  let groups = Hashtbl.create 16 in
  let ordered_keys = ref [] in
  let ensure_group group_type group_id =
    let key = clock_group_key group_type group_id in
    match Hashtbl.find_opt groups key with
    | Some group -> group
    | None ->
      let group =
        { group_type
        ; group_id
        ; edge_count = 0
        ; edge_ids = []
        ; lanes = []
        ; events = []
        ; statuses = []
        ; first_observed_at = None
        ; last_observed_at = None
        ; terminal_events = []
        ; parent_event_ids = []
        ; caused_by = []
        ; event_bus_event_count = 0
        ; event_bus_payload_kinds = []
        }
      in
      Hashtbl.replace groups key group;
      ordered_keys := !ordered_keys @ [ key ];
      group
  in
  let update_group group_type group_id edge =
    let group = ensure_group group_type group_id in
    let event = option_string_default "unknown_event" (edge_string "event" edge) in
    group.edge_count <- group.edge_count + 1;
    (match edge_string "edge_id" edge with
     | Some value -> group.edge_ids <- add_unique_non_empty value group.edge_ids
     | None -> ());
    (match edge_string "lane" edge with
     | Some value -> group.lanes <- add_unique_non_empty value group.lanes
     | None -> ());
    group.events <- add_unique_non_empty event group.events;
    (match edge_string "status" edge with
     | Some value -> group.statuses <- add_unique_non_empty value group.statuses
     | None -> ());
    (match edge_string "observed_at" edge with
     | Some value ->
       if group.first_observed_at = None then group.first_observed_at <- Some value;
       group.last_observed_at <- Some value
     | None -> ());
    if clock_group_terminal_event group_type event then
      group.terminal_events <- add_unique_non_empty event group.terminal_events;
    (match edge_string "parent_event_id" edge with
     | Some value ->
       group.parent_event_ids <- add_unique_non_empty value group.parent_event_ids
     | None -> ());
    (match edge_string "caused_by" edge with
     | Some value -> group.caused_by <- add_unique_non_empty value group.caused_by
     | None -> ());
    (match edge_int "event_bus_event_count" edge with
     | Some count -> group.event_bus_event_count <- group.event_bus_event_count + count
     | None -> ());
    group.event_bus_payload_kinds <-
      List.fold_left
        (fun acc value -> add_unique_non_empty value acc)
        group.event_bus_payload_kinds
        (edge_string_list "event_bus_payload_kinds" edge)
  in
  let add_if_present edge group_type field =
    match edge_string field edge with
    | Some group_id when String.trim group_id <> "" -> update_group group_type group_id edge
    | Some _ | None -> ()
  in
  Server_dashboard_http_keeper_runtime_lens_clock_edges.clock_edge_jsons scan
  |> List.iter (fun edge ->
    let turn_group_id =
      Printf.sprintf "%s:keeper-%s"
        (option_string_default "unknown_trace" (edge_string "trace_id" edge))
        (option_int_string (edge_int "keeper_turn_id" edge))
    in
    update_group "turn" turn_group_id edge;
    add_if_present edge "tool_batch" "tool_batch_id";
    add_if_present edge "provider_attempt" "provider_attempt_id";
    add_if_present edge "checkpoint" "checkpoint_id";
    add_if_present edge "compaction" "compaction_id";
    add_if_present edge "memory_injection" "memory_injection_id";
    add_if_present edge "event_bus_correlation" "event_bus_correlation_id");
  !ordered_keys
  |> List.filter_map (fun key -> Hashtbl.find_opt groups key)
  |> List.map (fun group ->
    `Assoc
      [ "group_type", `String group.group_type
      ; "group_id", `String group.group_id
      ; "edge_count", `Int group.edge_count
      ; "edge_ids", Json_util.json_string_list group.edge_ids
      ; "lanes", Json_util.json_string_list group.lanes
      ; "events", Json_util.json_string_list group.events
      ; "statuses", Json_util.json_string_list group.statuses
      ; "first_observed_at", json_string_opt group.first_observed_at
      ; "last_observed_at", json_string_opt group.last_observed_at
      ; "closed", `Bool (group.terminal_events <> [])
      ; "terminal_events", Json_util.json_string_list group.terminal_events
      ; "parent_event_ids", Json_util.json_string_list group.parent_event_ids
      ; "caused_by", Json_util.json_string_list group.caused_by
      ; "event_bus_event_count", `Int group.event_bus_event_count
      ; "event_bus_payload_kinds", Json_util.json_string_list group.event_bus_payload_kinds
      ])
  |> fun edges -> `List edges

let clock_group_jsons scan =
  match runtime_lens_clock_groups_json scan with
  | `List groups -> groups
  | _ -> []

let take_n n values =
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | value :: rest -> loop (value :: acc) (remaining - 1) rest
  in
  loop [] n values

let preview_values values =
  let first = take_n 4 values in
  let suffix = if List.length values > List.length first then [ "..." ] else [] in
  String.concat ", " (first @ suffix)

let clock_group_open_gap ~code ~severity ~lane ~label groups =
  let open_ids =
    groups
    |> List.filter_map (fun group ->
      match json_bool_member_opt "closed" group, json_string_member_opt "group_id" group with
      | Some false, Some group_id when String.trim group_id <> "" -> Some group_id
      | _ -> None)
  in
  match open_ids with
  | [] -> None
  | _ ->
    Some
      { code
      ; severity
      ; lane
      ; detail =
          Some
            (Printf.sprintf "%s open groups=%d (%s)" label (List.length open_ids)
               (preview_values open_ids))
      }

let runtime_lens_clock_group_gaps scan =
  let groups = clock_group_jsons scan in
  let groups_of_type group_type =
    List.filter
      (fun group -> json_string_member_opt "group_type" group = Some group_type)
      groups
  in
  let edge_ids =
    Server_dashboard_http_keeper_runtime_lens_clock_edges.clock_edge_jsons scan
    |> List.filter_map (fun edge -> edge_string "edge_id" edge)
    |> List.fold_left (fun acc value -> add_unique_non_empty value acc) []
  in
  let missing_parent_ids =
    Server_dashboard_http_keeper_runtime_lens_clock_edges.clock_edge_jsons scan
    |> List.filter_map (fun edge -> edge_string "parent_event_id" edge)
    |> List.filter (fun parent_id -> not (List.mem parent_id edge_ids))
    |> List.fold_left (fun acc value -> add_unique_non_empty value acc) []
  in
  []
  |> (fun gaps ->
       match
         clock_group_open_gap ~code:"clock_tool_batch_open" ~severity:"warn"
           ~lane:"tool_runtime" ~label:"tool_batch" (groups_of_type "tool_batch")
       with
       | Some gap -> gap :: gaps
       | None -> gaps)
  |> (fun gaps ->
       match
         clock_group_open_gap ~code:"clock_provider_group_open"
           ~severity:(if scan.has_terminal then "bad" else "warn") ~lane:"provider"
           ~label:"provider_attempt" (groups_of_type "provider_attempt")
       with
       | Some gap -> gap :: gaps
       | None -> gaps)
  |> (fun gaps ->
       match
         clock_group_open_gap ~code:"clock_checkpoint_group_open" ~severity:"warn"
           ~lane:"oas_agent" ~label:"checkpoint" (groups_of_type "checkpoint")
       with
       | Some gap -> gap :: gaps
       | None -> gaps)
  |> (fun gaps ->
       match
         clock_group_open_gap ~code:"clock_memory_injection_unflushed"
           ~severity:"warn" ~lane:"memory_context" ~label:"memory_injection"
           (groups_of_type "memory_injection")
       with
       | Some gap -> gap :: gaps
       | None -> gaps)
  |> (fun gaps ->
       match
         clock_group_open_gap ~code:"clock_compaction_group_open" ~severity:"warn"
           ~lane:"memory_context" ~label:"compaction" (groups_of_type "compaction")
       with
       | Some gap -> gap :: gaps
       | None -> gaps)
  |> (fun gaps ->
       match missing_parent_ids with
       | [] -> gaps
       | _ ->
         { code = "clock_parent_edge_missing"
         ; severity = "warn"
         ; lane = "keeper"
         ; detail =
             Some
               (Printf.sprintf "parent_event_id references missing edges: %s"
                  (preview_values missing_parent_ids))
         }
         :: gaps)
  |> List.rev

let runtime_lens_clock_gaps scan =
  let event_count = runtime_manifest_scan_event_count scan in
  let has_tool_surface =
    event_count Keeper_runtime_manifest.Tool_surface_selected > 0
  in
  let checkpoint_saved_count =
    event_count Keeper_runtime_manifest.Checkpoint_saved
  in
  let returned_row_count = Queue.length scan.returned_rows in
  let add ~code ~severity ~lane ~detail gaps =
    { code; severity; lane; detail = Some detail } :: gaps
  in
  []
  |> (fun gaps ->
       if scan.total_rows > returned_row_count then
         add ~code:"clock_edges_window_truncated" ~severity:"info"
           ~lane:"keeper"
           ~detail:
             (Printf.sprintf
                "clock_edges contains the latest %d of %d manifest rows; \
                 increase the runtime-trace limit to inspect the full clock"
                returned_row_count scan.total_rows)
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_started_count > 0 && not has_tool_surface then
         add ~code:"tool_surface_missing" ~severity:"bad"
           ~lane:"tool_runtime"
           ~detail:
             "provider attempt exists without a tool_surface_selected row"
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_started_count > scan.provider_finished_count then
         add ~code:"clock_provider_attempt_unfinished"
           ~severity:(if scan.has_terminal then "bad" else "warn")
           ~lane:"provider"
           ~detail:
             (Printf.sprintf
                "provider attempts started=%d finished=%d"
                scan.provider_started_count scan.provider_finished_count)
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_finished_count > scan.provider_started_count then
         add ~code:"clock_provider_attempt_finished_without_start"
           ~severity:"bad" ~lane:"provider"
           ~detail:
             (Printf.sprintf
                "provider attempts finished=%d started=%d"
                scan.provider_finished_count scan.provider_started_count)
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.provider_started_count > 0 && scan.context_injected_count = 0
       then
         add ~code:"clock_context_injection_missing" ~severity:"warn"
           ~lane:"memory_context"
           ~detail:
             "provider attempt exists without a context_injected clock edge"
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.event_bus_count > 0
          && scan.event_bus_correlation_ids = []
          && scan.event_bus_run_ids = []
       then
         add ~code:"clock_event_bus_uncorrelated" ~severity:"warn"
           ~lane:"memory_context"
           ~detail:"event_bus_correlated rows have no correlation_id or run_id"
           gaps
       else gaps)
  |> (fun gaps ->
       if checkpoint_saved_count > 0 && scan.context_injected_count = 0 then
         add ~code:"clock_checkpoint_without_context" ~severity:"warn"
           ~lane:"oas_agent"
           ~detail:
             "checkpoint_saved exists without a context_injected clock edge"
           gaps
       else gaps)
  |> List.rev
  |> fun gaps -> gaps @ runtime_lens_clock_group_gaps scan
