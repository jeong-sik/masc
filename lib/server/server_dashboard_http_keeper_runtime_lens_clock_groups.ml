(** Runtime-lens clock-group projection and gap detection.

    Derives grouped clock edges (turns, batches, attempts, checkpoints,
    and event-bus correlations) from the edge
    stream produced by {!Server_dashboard_http_keeper_runtime_lens_clock_edges}. *)

open Server_dashboard_http_keeper_runtime_manifest_scan
open Server_dashboard_http_keeper_runtime_lens_swimlane

let edge_string key edge = Json_util.get_string edge key
let edge_int key edge = Json_util.get_int edge key
let edge_string_list key edge = Json_util.get_string_list edge key

let add_unique value values =
  if List.mem value values then values else values @ [ value ]

let add_unique_non_empty value values =
  let value = String.trim value in
  if value = "" then values else add_unique value values

let option_string_default default = function
  | Some value when Option.is_some (String_util.trim_nonempty value) -> value
  | Some _ | None -> default

let option_int_string = function
  | Some value -> string_of_int value
  | None -> "unknown"

type clock_group_acc =
  { group_type : string
  ; group_id : string
  ; edge_count : int
  ; edge_ids : string list
  ; lanes : string list
  ; events : string list
  ; statuses : string list
  ; first_observed_at : string option
  ; last_observed_at : string option
  ; terminal_events : string list
  ; parent_event_ids : string list
  ; caused_by : string list
  ; event_bus_event_count : int
  ; event_bus_payload_kinds : string list
  }

let clock_group_terminal_event group_type event =
  match group_type, event with
  | "turn", ("turn_finished" | "pre_dispatch_blocked") -> true
  | "tool_batch", "provider_lane_resolved" -> true
  | "checkpoint", "checkpoint_saved" -> true
  | "event_bus_correlation", "event_bus_correlated" -> true
  | _ -> false

let clock_group_key group_type group_id = group_type ^ "\000" ^ group_id

let runtime_lens_clock_groups_json scan =
  let groups = Hashtbl.create 16 in
  let ordered_keys = ref [] in
  let ensure_group group_type group_id =
    let key = clock_group_key group_type group_id in
    match Hashtbl.find_opt groups key with
    | Some group -> key, group
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
      key, group
  in
  (* The table owns the group, so an edge folds in by rebinding the entry.
     Every field reads [group] from before this edge, matching what the
     in-place writes observed. *)
  let update_group group_type group_id edge =
    let key, group = ensure_group group_type group_id in
    let event = option_string_default "unknown_event" (edge_string "event" edge) in
    let observed_at = edge_string "observed_at" edge in
    let updated =
      { group with
        edge_count = group.edge_count + 1
      ; edge_ids =
          (match edge_string "edge_id" edge with
           | Some value -> add_unique_non_empty value group.edge_ids
           | None -> group.edge_ids)
      ; lanes =
          (match edge_string "lane" edge with
           | Some value -> add_unique_non_empty value group.lanes
           | None -> group.lanes)
      ; events = add_unique_non_empty event group.events
      ; statuses =
          (match edge_string "status" edge with
           | Some value -> add_unique_non_empty value group.statuses
           | None -> group.statuses)
      ; first_observed_at =
          (match observed_at, group.first_observed_at with
           | Some value, None -> Some value
           | (Some _ | None), existing -> existing)
      ; last_observed_at =
          (match observed_at with
           | Some value -> Some value
           | None -> group.last_observed_at)
      ; terminal_events =
          (if clock_group_terminal_event group_type event
           then add_unique_non_empty event group.terminal_events
           else group.terminal_events)
      ; parent_event_ids =
          (match edge_string "parent_event_id" edge with
           | Some value -> add_unique_non_empty value group.parent_event_ids
           | None -> group.parent_event_ids)
      ; caused_by =
          (match edge_string "caused_by" edge with
           | Some value -> add_unique_non_empty value group.caused_by
           | None -> group.caused_by)
      ; event_bus_event_count =
          (match edge_int "event_bus_event_count" edge with
           | Some count -> group.event_bus_event_count + count
           | None -> group.event_bus_event_count)
      ; event_bus_payload_kinds =
          List.fold_left
            (fun acc value -> add_unique_non_empty value acc)
            group.event_bus_payload_kinds
            (edge_string_list "event_bus_payload_kinds" edge)
      }
    in
    Hashtbl.replace groups key updated
  in
  let add_if_present edge group_type field =
    match edge_string field edge with
    | Some group_id when Option.is_some (String_util.trim_nonempty group_id) -> update_group group_type group_id edge
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
    add_if_present edge "checkpoint" "checkpoint_id";
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
      ; "first_observed_at", Json_util.string_opt_to_json group.first_observed_at
      ; "last_observed_at", Json_util.string_opt_to_json group.last_observed_at
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

let take_n = List.take

let preview_values values =
  let first = take_n 4 values in
  let suffix = if List.length values > List.length first then [ "..." ] else [] in
  String.concat ", " (first @ suffix)

let clock_group_open_gap ~code ~severity ~lane ~label groups =
  let open_ids =
    groups
    |> List.filter_map (fun group ->
      match Json_util.get_bool group "closed", Json_util.get_string group "group_id" with
      | Some false, Some group_id -> String_util.trim_nonempty group_id
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
      (fun group -> Json_util.get_string group "group_type" = Some group_type)
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
         clock_group_open_gap ~code:"clock_checkpoint_group_open" ~severity:"warn"
           ~lane:"agent_core_agent" ~label:"checkpoint" (groups_of_type "checkpoint")
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
       if scan.has_terminal && scan.context_injected_count = 0
       then
         add ~code:"clock_context_injection_missing" ~severity:"warn"
           ~lane:"memory_context"
           ~detail:"turn finished without a context_injected clock edge"
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
           ~lane:"agent_core_agent"
           ~detail:
             "checkpoint_saved exists without a context_injected clock edge"
           gaps
       else gaps)
  |> List.rev
  |> fun gaps -> gaps @ runtime_lens_clock_group_gaps scan
