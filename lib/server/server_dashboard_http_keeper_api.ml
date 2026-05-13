(** Keeper HTTP API handlers — tool policy, config update, lifecycle.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains POST handler logic for /api/v1/keepers/:name/tools,
    /config, /boot, /shutdown endpoints. *)

module Http = Http_server_eio

(* ── Keeper route constants (SSOT) ────────────────────────────── *)

let keeper_api_prefix = "/api/v1/keepers/"
let keeper_suffix_tools = "/tools"
let keeper_suffix_config = "/config"
let keeper_suffix_boot = "/boot"
let keeper_suffix_shutdown = "/shutdown"
let keeper_suffix_reset = "/reset"
let keeper_suffix_clear = "/clear"
let keeper_suffix_checkpoints = "/checkpoints"
let keeper_suffix_runtime_trace = "/runtime-trace"
let keeper_suffix_directive = "/directive"
let keeper_suffix_bdi_snapshot = "/bdi-snapshot"

let dedupe_tool_names names =
  Json_util.dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

let trajectory_line_ts = function
  | Trajectory.Tool_call entry -> entry.ts
  | Trajectory.Thinking entry -> entry.ts

let dedupe_thinking_lines (lines : Trajectory.trajectory_line list)
    : Trajectory.trajectory_line list =
  let seen = Hashtbl.create 32 in
  List.filter
    (function
      | Trajectory.Tool_call _ -> true
      | Trajectory.Thinking entry ->
          let key =
            Printf.sprintf "%.6f\x1f%b\x1f%s"
              entry.ts entry.redacted entry.content
          in
          if Hashtbl.mem seen key then false
          else (
            Hashtbl.add seen key ();
            true))
    lines

let internal_history_json_to_trajectory_line (json : Yojson.Safe.t)
    : Trajectory.trajectory_line option =
  let source = Safe_ops.json_string ~default:"" "source" json in
  let content = Safe_ops.json_string ~default:"" "content" json in
  if source <> "internal_assistant" || String.trim content = "" then None
  else
    let ts =
      match Safe_ops.json_float_opt "ts_unix" json with
      | Some value when value > 0.0 -> value
      | _ ->
          match Safe_ops.json_float_opt "timestamp" json with
          | Some value when value > 0.0 -> value
          | _ -> 0.0
    in
    if ts <= 0.0 then None
    else
      let ts_iso =
        match Safe_ops.json_string_opt "ts_iso" json with
        | Some value when String.trim value <> "" -> value
        | _ ->
            match Safe_ops.json_string_opt "ts" json with
            | Some value when String.trim value <> "" -> value
            | _ -> Dashboard_utils.iso_of_unix ts
      in
      Some
        (Trajectory.Thinking
           {
             ts;
             ts_iso;
             turn = Safe_ops.json_int ~default:0 "turn" json;
             content;
             content_length = String.length content;
             redacted = Safe_ops.json_bool ~default:false "redacted" json;
           })

let read_internal_history_lines ~(config : Coord.config) ~(trace_id : string)
    : Trajectory.trajectory_line list =
  let path = Keeper_types.keeper_internal_history_path config trace_id in
  (* Streaming filter — avoid materialising the full JSONL list when
     only a subset of lines decode to [trajectory_line]. Output is built
     in reverse and reversed once, matching List.filter_map ordering. *)
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no:_ json ->
      match internal_history_json_to_trajectory_line json with
      | Some line -> line :: acc
      | None -> acc)
    path
  |> List.rev

let merge_keeper_trace_lines ~(config : Coord.config) ~(trace_id : string)
    (trajectory_lines : Trajectory.trajectory_line list)
    : Trajectory.trajectory_line list =
  let internal_lines = read_internal_history_lines ~config ~trace_id in
  dedupe_thinking_lines (trajectory_lines @ internal_lines)
  |> List.sort (fun left right ->
         let cmp = Float.compare (trajectory_line_ts left) (trajectory_line_ts right) in
         if cmp <> 0 then cmp
         else
           match left, right with
           | Trajectory.Thinking _, Trajectory.Tool_call _ -> -1
           | Trajectory.Tool_call _, Trajectory.Thinking _ -> 1
           | _ -> 0)

let keeper_tools_response_json (meta : Keeper_types.keeper_meta) =
  let allowed = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let masc_count = List.length (Keeper_exec_tools.keeper_masc_tool_names meta) in
  `Assoc
    [
      ("ok", `Bool true);
      ("tool_access", Keeper_types.tool_access_to_json meta.tool_access);
      ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
      ("tool_denylist", `List (List.map (fun s -> `String s) meta.tool_denylist));
      ("active_masc_tool_count", `Int masc_count);
      ("total_active", `Int (List.length allowed));
    ]

(** Handle POST /api/v1/keepers/:name/tools.
    Extracted so it can be called from any prefix_post handler that
    catches POST /api/v1/keepers/* requests. *)
let handle_keeper_tools_post state req reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let req_path = Http.Request.path req in
    let prefix = keeper_api_prefix in
    let suffix = keeper_suffix_tools in
    let plen = String.length prefix in
    let slen = String.length suffix in
    let tlen = String.length req_path in
    let name = String.trim (String.sub req_path plen (tlen - plen - slen)) in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request {|{"error":"keeper name required"}|} reqd
    else
      let config = state.Mcp_server.room_config in
      match Keeper_types.read_meta config name with
      | Error msg ->
          Http.Response.json ~status:`Not_found
            (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
      | Ok None ->
          Http.Response.json ~status:`Not_found
            (Printf.sprintf {|{"error":"keeper %S not found"}|} name) reqd
      | Ok (Some meta) ->
          (try
             let args = Yojson.Safe.from_string body_str in
             let action = Safe_ops.json_string ~default:"" "action" args in
             let updated_meta =
               match action with
               | "set_policy" ->
                   let deny =
                     Safe_ops.json_string_list "deny" args |> dedupe_tool_names
                   in
                   let tool_access_result =
                     match Yojson.Safe.Util.member "tool_access" args with
                     | `Assoc _ as access_json ->
                         Keeper_types.tool_access_of_meta_json
                           (`Assoc [ ("tool_access", access_json) ])
                     | `Null -> Error "tool_access required"
                     | _ -> Error "tool_access must be an object"
                   in
                   Result.map
                     (fun tool_access ->
                       {
                         meta with
                         tool_access;
                         tool_denylist = deny;
                         updated_at = Keeper_types.now_iso ();
                       })
                     tool_access_result
               | "" -> Error "action required (set_policy)"
               | other -> Error (Printf.sprintf "unknown action: %s" other)
             in
             (match updated_meta with
             | Error msg ->
                 Http.Response.json ~status:`Bad_request
                   (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
             | Ok meta' ->
                 (* force: user-initiated tool config is authoritative.
                    Skips version CAS since user intent overrides
                    concurrent keeper turn updates. *)
                 (match Keeper_types.write_meta ~force:true config meta' with
                  | Ok () ->
                      Http.Response.json ~compress:true ~request:req
                        (Yojson.Safe.to_string (keeper_tools_response_json meta')) reqd
                  | Error e ->
                      Http.Response.json ~status:`Internal_server_error
                        (Printf.sprintf {|{"error":"write failed: %s"}|} (String.escaped e)) reqd))
           with Yojson.Json_error e ->
             Http.Response.json ~status:`Bad_request
               (Printf.sprintf {|{"error":"invalid json: %s"}|} (String.escaped e)) reqd))

type keeper_post_route_kind =
  | Keeper_post_tools
  | Keeper_post_config
  | Keeper_post_boot
  | Keeper_post_shutdown
  | Keeper_post_reset
  | Keeper_post_clear
  | Keeper_post_checkpoints
  | Keeper_post_directive
  | Keeper_post_unknown

let classify_keeper_post_route req_path =
  (* Hoist the prefix check out of the per-suffix loop and route both
     comparisons through Stdlib's allocation-free [starts_with] /
     [ends_with]. Old form ran [String.sub req_path 0 plen] once per
     suffix candidate (8x) plus a fresh suffix [String.sub] each time —
     up to 16 allocations per keeper API request. *)
  if not (String.starts_with ~prefix:keeper_api_prefix req_path) then
    Keeper_post_unknown
  else
    let plen = String.length keeper_api_prefix in
    let tlen = String.length req_path in
    let ends_with suffix =
      tlen > plen + String.length suffix
      && String.ends_with ~suffix req_path
    in
    if ends_with keeper_suffix_tools then Keeper_post_tools
    else if ends_with keeper_suffix_config then Keeper_post_config
    else if ends_with keeper_suffix_boot then Keeper_post_boot
    else if ends_with keeper_suffix_shutdown then Keeper_post_shutdown
    else if ends_with keeper_suffix_reset then Keeper_post_reset
    else if ends_with keeper_suffix_clear then Keeper_post_clear
    else if ends_with keeper_suffix_checkpoints then Keeper_post_checkpoints
    else if ends_with keeper_suffix_directive then Keeper_post_directive
    else Keeper_post_unknown

let keeper_path_ends_with req_path suffix =
  let plen = String.length keeper_api_prefix in
  let tlen = String.length req_path in
  let slen = String.length suffix in
  tlen > plen + slen
  && String.starts_with ~prefix:keeper_api_prefix req_path
  && String.ends_with ~suffix req_path

let extract_keeper_name_for_suffix req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  let valid =
    String.length raw > 0
    && String.length raw <= 128
    && String.to_seq raw
       |> Seq.for_all (fun c ->
            (c >= 'a' && c <= 'z')
            || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c = '_' || c = '-')
  in
  if valid then raw else ""

let is_keeper_checkpoints_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_checkpoints

let is_keeper_runtime_trace_get_path req_path =
  keeper_path_ends_with req_path keeper_suffix_runtime_trace

let trim_to_opt (value : string) =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let truncate_text ~max_chars text =
  let len = String.length text in
  if len <= max_chars then text
  else if max_chars <= 1 then String.sub text 0 (max 0 max_chars)
  else
    String_util.utf8_safe ~max_bytes:max_chars ~suffix:"…" text
    |> String_util.to_string

let latest_preview_of_messages (messages : Agent_sdk.Types.message list) =
  messages
  |> List.rev
  |> List.find_map (fun (message : Agent_sdk.Types.message) ->
       if message.role = Agent_sdk.Types.System then None
       else
         Agent_sdk.Types.text_of_message message
         |> trim_to_opt
         |> Option.map (truncate_text ~max_chars:180))

let continuity_summary_of_messages (messages : Agent_sdk.Types.message list) =
  match Keeper_memory_policy.latest_state_snapshot_from_messages messages with
  | Some snapshot ->
      Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
      |> trim_to_opt
  | None -> None

let stat_json_of_path (path : string) =
  try
    let stat = Unix.stat path in
    `Assoc
      [
        ("size_bytes", `Int stat.st_size);
        ("mtime", `Float stat.st_mtime);
      ]
  with
  | Unix.Unix_error _ -> `Null

let oas_checkpoint_summary_json
    ~(source_kind : string)
    ~(snapshot_id : string)
    ~(path : string)
    ~(is_current : bool)
    ~(fallback_generation : int)
    (checkpoint : Agent_sdk.Checkpoint.t) =
  let generation =
    Keeper_context_core.checkpoint_generation checkpoint
      ~fallback:fallback_generation
  in
  let messages = checkpoint.messages in
  let continuity_summary = continuity_summary_of_messages messages in
  `Assoc
    [
      ("snapshot_id", `String snapshot_id);
      ("source_kind", `String source_kind);
      ("is_current", `Bool is_current);
      ("path", `String path);
      ("created_at", `Float checkpoint.created_at);
      ("generation", `Int generation);
      ("message_count", `Int (List.length messages));
      ( "system_prompt_present",
        `Bool
          (match checkpoint.system_prompt with
           | Some prompt -> String.trim prompt <> ""
           | None -> false) );
      ( "latest_preview",
        match latest_preview_of_messages messages with
        | Some preview -> `String preview
        | None -> `Null );
      ( "continuity_summary",
        match continuity_summary with
        | Some summary -> `String summary
        | None -> `Null );
      ("file_stat", stat_json_of_path path);
    ]

let keeper_checkpoint_inventory_json
    (config : Coord.config)
    (name : string) : [ `OK | `Not_found ] * Yojson.Safe.t =
  match Keeper_types.read_meta_resolved config name with
  | Error msg ->
      (`Not_found, `Assoc [("error", `String msg)])
  | Ok None ->
      (`Not_found,
       `Assoc [("error", `String (Printf.sprintf "keeper %S not found" name))])
  | Ok (Some (_, meta)) ->
      let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
      let session_dir = Keeper_types.keeper_session_dir config trace_id in
      let current_path =
        Keeper_checkpoint_store.oas_checkpoint_path
          ~session_dir ~session_id:trace_id
      in
      let current_json =
        match
          Keeper_checkpoint_store.load_oas ~session_dir ~session_id:trace_id
        with
        | Ok checkpoint ->
            let current_history_snapshot_id =
              Keeper_checkpoint_store.oas_history_snapshot_id_of_checkpoint checkpoint
            in
            oas_checkpoint_summary_json
              ~source_kind:"oas_current"
              ~snapshot_id:(Filename.basename current_path)
              ~path:current_path
              ~is_current:true
              ~fallback_generation:meta.runtime.generation
              checkpoint
            |> fun json -> Some (json, current_history_snapshot_id)
        | Error _ -> None
      in
      let history_json =
        Keeper_checkpoint_store.list_oas_history_files ~session_dir
        |> List.filter (fun snapshot_id ->
             match current_json with
             | Some (_json, current_history_snapshot_id) ->
                 snapshot_id <> current_history_snapshot_id
             | None -> true)
        |> List.filter_map (fun snapshot_id ->
             match
               Keeper_checkpoint_store.load_oas_history_file
                 ~session_dir ~snapshot_id
             with
             | Ok checkpoint ->
                 Some
                   (oas_checkpoint_summary_json
                      ~source_kind:"oas_history"
                      ~snapshot_id
                      ~path:
                        (Keeper_checkpoint_store.oas_history_path
                           ~session_dir ~snapshot_id)
                      ~is_current:false
                      ~fallback_generation:meta.runtime.generation
                      checkpoint)
             | Error _ -> None)
      in
      ( `OK,
        `Assoc
          [
            ("keeper", `String name);
            ("trace_id", `String trace_id);
            ("session_dir", `String session_dir);
            ("current", match current_json with Some (json, _snapshot_id) -> json | None -> `Null);
            ("history", `List history_json);
            ( "legacy_shadow_count",
              `Int
                (List.length
                   (Keeper_checkpoint_store.list_checkpoints ~session_dir)) );
          ] )

let json_int_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Int value -> Some value
  | `Intlit raw -> int_of_string_opt raw
  | _ -> None

let json_string_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | _ -> None

let json_bool_member_opt name json =
  match Yojson.Safe.Util.member name json with
  | `Bool value -> Some value
  | _ -> None

let json_string_list_member name json =
  match Yojson.Safe.Util.member name json with
  | `List values ->
    values
    |> List.filter_map (function
      | `String value when String.trim value <> "" -> Some value
      | _ -> None)
    |> Json_util.dedupe_keep_order
  | _ -> []

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let take_last limit values =
  let len = List.length values in
  if len <= limit then values
  else List.filteri (fun idx _ -> idx >= len - limit) values

let unique_present_paths paths =
  paths
  |> List.filter_map (fun value ->
       match value with
       | Some path when String.trim path <> "" -> Some path
       | _ -> None)
  |> Json_util.dedupe_keep_order

let linked_artifact_json ~kind path =
  `Assoc
    [
      ("kind", `String kind);
      ("path", `String path);
      ("present", `Bool (Fs_compat.file_exists path));
      ("file_stat", stat_json_of_path path);
    ]

let manifest_row_matches ?turn_id keeper_name trace_id
    (row : Keeper_runtime_manifest.t) =
  String.equal row.keeper_name keeper_name
  && String.equal row.trace_id trace_id
  &&
  match turn_id with
  | None -> true
  | Some wanted -> row.keeper_turn_id = Some wanted

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

let receipt_row_matches ?turn_id keeper_name trace_id json =
  let keeper_matches = json_string_member_opt "keeper_name" json = Some keeper_name in
  let trace_matches = json_string_member_opt "trace_id" json = Some trace_id in
  let turn_matches =
    match turn_id with
    | None -> false
    | Some wanted -> json_int_member_opt "turn_count" json = Some wanted
  in
  keeper_matches && (trace_matches || turn_matches)

let read_receipt_rows ~keeper_name ~trace_id ?turn_id paths =
  paths
  |> List.concat_map (fun path ->
       Fs_compat.fold_jsonl_lines
         ~init:[]
         ~f:(fun acc ~line_no:_ json ->
           if receipt_row_matches ?turn_id keeper_name trace_id json then
             json :: acc
           else acc)
         path
       |> List.rev)

let unique_ints values =
  values
  |> List.sort_uniq Int.compare

let json_int_list values =
  `List (List.map (fun value -> `Int value) values)

let json_int_opt = function
  | None -> `Null
  | Some value -> `Int value

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let event_bus_summary_json scan =
  let correlation_ids =
    scan.event_bus_correlation_ids
    |> List.rev
    |> Json_util.dedupe_keep_order
  in
  let run_ids =
    scan.event_bus_run_ids |> List.rev |> Json_util.dedupe_keep_order
  in
  let last_compaction =
    match scan.last_compaction with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [
      ("event_bus_correlated_count", `Int scan.event_bus_count);
      ("correlation_ids", json_string_list correlation_ids);
      ("run_ids", json_string_list run_ids);
      ( "context_compact_started_count",
        `Int scan.context_compact_started_count );
      ( "context_compacted_count",
        `Int scan.context_compacted_count );
      ("last_compaction", last_compaction);
    ]

let memory_summary_json scan =
  `Assoc
    [
      ("memory_injected_count", `Int scan.memory_injected_count);
      ( "memory_injected_present_count",
        `Int scan.memory_injected_present_count );
      ("memory_flushed_count", `Int scan.memory_flushed_count);
      ("memory_flush_success_count", `Int scan.memory_flush_success_count);
      ("memory_flush_error_count", `Int scan.memory_flush_error_count);
      ("episodes_flushed", `Int scan.episodes_flushed);
      ("procedures_flushed", `Int scan.procedures_flushed);
    ]

type runtime_lens_gap =
  { code : string
  ; severity : string
  ; lane : string
  ; detail : string option
  }

let max_int_list_opt values =
  List.fold_left
    (fun acc value ->
      match acc with
      | None -> Some value
      | Some existing -> Some (max existing value))
    None
    values

let selected_keeper_turn_id ?turn_id scan =
  match turn_id with
  | Some value -> Some value
  | None -> max_int_list_opt scan.keeper_turn_ids

let terminal_event_present_for_turn ?keeper_turn_id scan =
  match keeper_turn_id with
  | Some value -> List.mem value scan.terminal_keeper_turn_ids
  | None -> scan.has_terminal

let first_non_empty_string_list values =
  match List.find_opt (fun values -> values <> []) values with
  | Some values -> values
  | None -> []

let first_string_opt values =
  List.find_map (fun value -> value) values

let first_int_opt values =
  List.find_map (fun value -> value) values

let runtime_lens_tool_surface_parts scan =
  let tool_decision =
    Option.value scan.latest_tool_surface_decision ~default:(`Assoc [])
  in
  let lane_decision =
    Option.value scan.latest_provider_lane_decision ~default:(`Assoc [])
  in
  let requested_tools =
    json_string_list_member "requested_tool_names" lane_decision
  in
  let required_tools =
    first_non_empty_string_list
      [
        json_string_list_member "required_tool_names" lane_decision;
        json_string_list_member "required_tool_names" tool_decision;
      ]
  in
  let materialized_tools =
    json_string_list_member "materialized_tool_names" lane_decision
  in
  let missing_required_tools =
    first_non_empty_string_list
      [
        json_string_list_member "missing_required_tool_names_after_lane"
          lane_decision;
        json_string_list_member "missing_required_tool_names" tool_decision;
      ]
  in
  ( tool_decision
  , lane_decision
  , requested_tools
  , required_tools
  , materialized_tools
  , missing_required_tools )

let runtime_lens_gap_json gap =
  `Assoc
    [
      ("code", `String gap.code);
      ("severity", `String gap.severity);
      ("lane", `String gap.lane);
      ("detail", json_string_opt gap.detail);
    ]

let runtime_lens_gaps ~terminal_event_present scan =
  let ( _
      , _
      , _
      , required_tools
      , materialized_tools
      , missing_required_tools )
    =
    runtime_lens_tool_surface_parts scan
  in
  let has_tool_surface =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Tool_surface_selected
    > 0
  in
  let has_provider_lane =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Provider_lane_resolved
    > 0
  in
  let has_context_delta =
    scan.context_injected_count > 0
    || scan.context_compacted_event_count > 0
    || scan.event_bus_count > 0
  in
  let add gap gaps = gap :: gaps in
  []
  |> (fun gaps ->
       if scan.total_rows > 0 && not terminal_event_present then
         add
           { code = "missing_turn_finished"
           ; severity = "warn"
           ; lane = "keeper"
           ; detail = Some "manifest has rows but no turn_finished row"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if missing_required_tools <> [] then
         add
           { code = "required_tool_not_materialized"
           ; severity = "bad"
           ; lane = "tool_runtime"
           ; detail =
               Some
                 (Printf.sprintf "missing required tools: %s"
                    (String.concat ", " missing_required_tools))
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if (has_tool_surface || scan.provider_started_count > 0)
          && not has_provider_lane
       then
         add
           { code = "provider_lane_unresolved"
           ; severity = "bad"
           ; lane = "masc_policy_cascade"
           ; detail = Some "tool surface/provider attempt exists without provider_lane_resolved"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if (has_tool_surface || scan.provider_started_count > 0)
          && not has_context_delta
       then
         add
           { code = "context_delta_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "provider turn has no context or event-bus delta rows"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if scan.memory_injected_count > 0 && scan.memory_flushed_count = 0 then
         add
           { code = "memory_flush_missing"
           ; severity = "warn"
           ; lane = "memory_context"
           ; detail = Some "memory was injected but no memory_flushed row was recorded"
           }
           gaps
       else gaps)
  |> (fun gaps ->
       if required_tools <> [] && materialized_tools = []
          && missing_required_tools = []
       then
         add
           { code = "provider_lane_unresolved"
           ; severity = "warn"
           ; lane = "masc_policy_cascade"
           ; detail = Some "required tools exist but provider lane materialization is unknown"
           }
           gaps
       else gaps)
  |> List.rev

let runtime_lens_gap_codes_for_lane gaps lane =
  gaps
  |> List.filter_map (fun gap ->
       if String.equal gap.lane lane then Some gap.code else None)
  |> Json_util.dedupe_keep_order

let runtime_lens_event_count scan event =
  runtime_manifest_scan_event_count scan event

let runtime_lens_events_json scan events =
  events
  |> List.filter_map (fun event ->
       let count = runtime_lens_event_count scan event in
       if count = 0 then None
       else
         Some
           (`Assoc
             [
               ( "event",
                 `String (Keeper_runtime_manifest.event_kind_to_string event) );
               ("count", `Int count);
             ]))
  |> fun events -> `List events

let runtime_lens_swimlane_json scan gaps ~lane ~label ~events ~terminal_status =
  let gap_codes = runtime_lens_gap_codes_for_lane gaps lane in
  let event_count =
    events
    |> List.fold_left
         (fun total event -> total + runtime_lens_event_count scan event)
         0
  in
  `Assoc
    [
      ("lane", `String lane);
      ("label", `String label);
      ("event_count", `Int event_count);
      ("terminal_status", `String terminal_status);
      ("gap_codes", json_string_list gap_codes);
      ( "gap_badge",
        match gap_codes with
        | code :: _ -> `String code
        | [] -> `Null );
      ("events", runtime_lens_events_json scan events);
    ]

let runtime_lens_keeper_terminal_status ~terminal_event_present scan =
  if terminal_event_present then "finished"
  else if
    runtime_lens_event_count scan Keeper_runtime_manifest.Pre_dispatch_blocked
    > 0
  then "blocked"
  else if scan.total_rows = 0 then "empty"
  else "open"

let runtime_lens_provider_terminal_status scan =
  match scan.provider_terminal_row with
  | Some row -> row.Keeper_runtime_manifest.status
  | None when scan.provider_started_count > scan.provider_finished_count ->
    "unfinished"
  | None when scan.provider_started_count = 0 -> "not_started"
  | None -> "unknown"

let runtime_lens_memory_terminal_status scan =
  if scan.memory_flush_error_count > 0 then "memory_error"
  else if scan.memory_flush_success_count > 0 then "flushed"
  else if scan.memory_injected_count > 0 then "injected"
  else if
    scan.context_injected_count > 0
    || scan.context_compacted_event_count > 0
    || scan.event_bus_count > 0
  then "context"
  else "empty"

let runtime_lens_json ~trace_id ?turn_id scan =
  let ( tool_decision
      , lane_decision
      , requested_tools
      , required_tools
      , materialized_tools
      , missing_required_tools )
    =
    runtime_lens_tool_surface_parts scan
  in
  let keeper_turn_id = selected_keeper_turn_id ?turn_id scan in
  let terminal_event_present =
    terminal_event_present_for_turn ?keeper_turn_id scan
  in
  let gaps = runtime_lens_gaps ~terminal_event_present scan in
  let has_provider_lane =
    runtime_manifest_scan_event_count scan
      Keeper_runtime_manifest.Provider_lane_resolved
    > 0
  in
  let provider_lane_status =
    Option.map
      (fun row -> row.Keeper_runtime_manifest.status)
      scan.latest_provider_lane_row
  in
  let tool_runtime_status =
    if missing_required_tools <> [] then "missing_required_tool"
    else if
      runtime_lens_event_count scan
        Keeper_runtime_manifest.Tool_surface_selected
      > 0
    then "selected"
    else "empty"
  in
  `Assoc
    [
      ( "turn_clock",
        `Assoc
          [
            ("trace_id", `String trace_id);
            ("keeper_turn_id", json_int_opt keeper_turn_id);
            ("max_oas_turn_count", json_int_opt scan.max_oas_turn_count);
            ("terminal_event_present", `Bool terminal_event_present);
            ( "terminal_event",
              if terminal_event_present then `String "turn_finished" else `Null );
            ("manifest_total_rows", `Int scan.total_rows);
          ] );
      ( "axes",
        `Assoc
          [
            ( "lifecycle",
              `Assoc
                [
                  ( "turn_started_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Turn_started) );
                  ( "phase_gate_decided_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Phase_gate_decided) );
                  ( "pre_dispatch_blocked_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Pre_dispatch_blocked) );
                  ( "receipt_appended_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Receipt_appended) );
                  ( "turn_finished_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Turn_finished) );
                  ( "terminal_status",
                    `String
                      (runtime_lens_keeper_terminal_status
                         ~terminal_event_present
                         scan) );
                ] );
            ( "tool_surface",
              `Assoc
                [
                  ("requested_tools", json_string_list requested_tools);
                  ("required_tools", json_string_list required_tools);
                  ("materialized_tools", json_string_list materialized_tools);
                  ( "missing_required_tools",
                    json_string_list missing_required_tools );
                  ( "turn_lane",
                    json_string_opt
                      (json_string_member_opt "turn_lane" tool_decision) );
                  ( "tool_surface_class",
                    json_string_opt
                      (json_string_member_opt "tool_surface_class"
                         tool_decision) );
                  ( "tool_requirement",
                    json_string_opt
                      (first_string_opt
                         [
                           json_string_member_opt "tool_requirement"
                             tool_decision;
                           json_string_member_opt "tool_requirement"
                             lane_decision;
                         ]) );
                  ( "visible_tool_count",
                    json_int_opt
                      (first_int_opt
                         [
                           json_int_member_opt "visible_tool_count"
                             tool_decision;
                           json_int_member_opt "effective_tool_count"
                             lane_decision;
                         ]) );
                  ( "tool_gate_enabled",
                    match
                      json_bool_member_opt "tool_gate_enabled" tool_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ( "tool_surface_fallback_used",
                    match
                      json_bool_member_opt "tool_surface_fallback_used"
                        tool_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ("terminal_status", `String tool_runtime_status);
                ] );
            ( "provider_lane",
              `Assoc
                [
                  ("resolved", `Bool has_provider_lane);
                  ("status", json_string_opt provider_lane_status);
                  ( "resolved_lane",
                    json_string_opt
                      (json_string_member_opt "resolved_lane" lane_decision)
                  );
                  ( "effective_tool_count",
                    json_int_opt
                      (json_int_member_opt "effective_tool_count"
                         lane_decision) );
                  ( "runtime_mcp_policy_present",
                    match
                      json_bool_member_opt "runtime_mcp_policy_present"
                        lane_decision
                    with
                    | Some value -> `Bool value
                    | None -> `Null );
                  ("required_tools", json_string_list required_tools);
                  ("materialized_tools", json_string_list materialized_tools);
                  ( "missing_required_tools",
                    json_string_list missing_required_tools );
                ] );
            ( "provider_attempt",
              `Assoc
                [
                  ("started_count", `Int scan.provider_started_count);
                  ("finished_count", `Int scan.provider_finished_count);
                  ( "terminal_status",
                    json_string_opt
                      (Option.map
                         (fun row -> row.Keeper_runtime_manifest.status)
                         scan.provider_terminal_row) );
                ] );
            ( "context",
              `Assoc
                [
                  ("context_injected_count", `Int scan.context_injected_count);
                  ( "context_compacted_event_count",
                    `Int scan.context_compacted_event_count );
                  ( "event_bus_correlated_count",
                    `Int scan.event_bus_count );
                  ( "context_compact_started_count",
                    `Int scan.context_compact_started_count );
                  ( "context_compacted_count",
                    `Int scan.context_compacted_count );
                  ( "checkpoint_loaded_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Checkpoint_loaded) );
                  ( "checkpoint_saved_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.Checkpoint_saved) );
                  ( "state_snapshot_sidecar_saved_count",
                    `Int
                      (runtime_lens_event_count scan
                         Keeper_runtime_manifest.State_snapshot_sidecar_saved)
                  );
                  ( "last_compaction",
                    match scan.last_compaction with
                    | Some value -> value
                    | None -> `Null );
                ] );
            ("memory", memory_summary_json scan);
          ] );
      ( "swimlanes",
        `Assoc
          [
            ( "keeper",
              runtime_lens_swimlane_json scan gaps ~lane:"keeper"
                ~label:"Keeper"
                ~events:
                  [
                    Keeper_runtime_manifest.Turn_started;
                    Keeper_runtime_manifest.Phase_gate_decided;
                    Keeper_runtime_manifest.Pre_dispatch_blocked;
                    Keeper_runtime_manifest.Receipt_appended;
                    Keeper_runtime_manifest.Turn_finished;
                  ]
                ~terminal_status:
                  (runtime_lens_keeper_terminal_status ~terminal_event_present scan)
            );
            ( "masc_policy_cascade",
              runtime_lens_swimlane_json scan gaps
                ~lane:"masc_policy_cascade" ~label:"MASC Cascade"
                ~events:
                  [
                    Keeper_runtime_manifest.Cascade_routed;
                    Keeper_runtime_manifest.Provider_lane_resolved;
                  ]
                ~terminal_status:
                  (Option.value provider_lane_status
                     ~default:
                       (if has_provider_lane then "resolved" else "empty"))
            );
            ( "oas_agent",
              runtime_lens_swimlane_json scan gaps ~lane:"oas_agent"
                ~label:"OAS"
                ~events:
                  [
                    Keeper_runtime_manifest.Checkpoint_loaded;
                    Keeper_runtime_manifest.State_snapshot_sidecar_saved;
                    Keeper_runtime_manifest.Checkpoint_saved;
                  ]
                ~terminal_status:
                  (if
                     runtime_lens_event_count scan
                       Keeper_runtime_manifest.Checkpoint_saved
                     > 0
                   then "checkpoint_saved"
                   else if
                     runtime_lens_event_count scan
                       Keeper_runtime_manifest.Checkpoint_loaded
                     > 0
                   then "checkpoint_loaded"
                   else "empty") );
            ( "provider",
              runtime_lens_swimlane_json scan gaps ~lane:"provider"
                ~label:"Provider"
                ~events:
                  [
                    Keeper_runtime_manifest.Provider_attempt_started;
                    Keeper_runtime_manifest.Provider_attempt_finished;
                  ]
                ~terminal_status:(runtime_lens_provider_terminal_status scan)
            );
            ( "tool_runtime",
              runtime_lens_swimlane_json scan gaps ~lane:"tool_runtime"
                ~label:"Tool Runtime"
                ~events:[ Keeper_runtime_manifest.Tool_surface_selected ]
                ~terminal_status:tool_runtime_status );
            ( "memory_context",
              runtime_lens_swimlane_json scan gaps ~lane:"memory_context"
                ~label:"Memory/Context"
                ~events:
                  [
                    Keeper_runtime_manifest.Context_injected;
                    Keeper_runtime_manifest.Context_compacted;
                    Keeper_runtime_manifest.Event_bus_correlated;
                    Keeper_runtime_manifest.Memory_injected;
                    Keeper_runtime_manifest.Memory_flushed;
                  ]
                ~terminal_status:(runtime_lens_memory_terminal_status scan) );
          ] );
      ("gaps", `List (List.map runtime_lens_gap_json gaps));
    ]

let provider_attempt_row_json (row : Keeper_runtime_manifest.t) =
  let decision_string key = json_string_member_opt key row.decision in
  `Assoc
    [
      ("ts", `String row.ts);
      ("event", `String (Keeper_runtime_manifest.event_kind_to_string row.event));
      ("cascade_name", json_string_opt row.cascade_name);
      ("model_source", json_string_opt (decision_string "model_source"));
      ( "resolved_model_source",
        json_string_opt (decision_string "resolved_model_source") );
      ("capability_source", json_string_opt (decision_string "capability_source"));
      ("fallback_authority", json_string_opt (decision_string "fallback_authority"));
      ( "provider_source_cascade",
        json_string_opt (decision_string "provider_source_cascade") );
      ("status", `String row.status);
      ("error", json_string_opt (decision_string "error"));
      ( "exception_kind",
        json_string_opt (decision_string "exception_kind") );
    ]

let string_contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let runtime_trace_redacts_provider_model_key key =
  let key = String.lowercase_ascii key in
  string_contains_substring key "provider"
  || string_contains_substring key "model"
  || String.equal key "configured_labels"

let rec runtime_trace_public_json = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.filter_map (fun (key, value) ->
               if runtime_trace_redacts_provider_model_key key then None
               else Some (key, runtime_trace_public_json value)))
  | `List values -> `List (List.map runtime_trace_public_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      value

let runtime_manifest_public_json row =
  Keeper_runtime_manifest.to_json row
  |> runtime_trace_public_json

let provider_attempts_summary_json scan =
  let attempt_rows = queue_to_list scan.provider_attempt_rows in
  let terminal = scan.provider_terminal_row in
  let terminal_decision_string key =
    Option.bind terminal (fun row ->
      json_string_member_opt key row.Keeper_runtime_manifest.decision)
  in
  `Assoc
    [
      ("started_count", `Int scan.provider_started_count);
      ("finished_count", `Int scan.provider_finished_count);
      ( "terminal_status",
        json_string_opt
          (Option.map (fun row -> row.Keeper_runtime_manifest.status) terminal) );
      ( "terminal_model_source",
        json_string_opt (terminal_decision_string "model_source") );
      ( "terminal_resolved_model_source",
        json_string_opt (terminal_decision_string "resolved_model_source") );
      ( "terminal_capability_source",
        json_string_opt (terminal_decision_string "capability_source") );
      ( "terminal_fallback_authority",
        json_string_opt (terminal_decision_string "fallback_authority") );
      ( "terminal_provider_source_cascade",
        json_string_opt (terminal_decision_string "provider_source_cascade") );
      ( "terminal_error",
        json_string_opt (terminal_decision_string "error") );
      ( "terminal_exception_kind",
        json_string_opt (terminal_decision_string "exception_kind") );
      ("attempts", `List (List.map provider_attempt_row_json attempt_rows));
    ]

let turn_identity_summary_json ?turn_id scan receipts =
  let manifest_keeper_turn_ids =
    scan.keeper_turn_ids
    |> List.rev
    |> unique_ints
  in
  let receipt_turn_counts =
    receipts
    |> List.filter_map (json_int_member_opt "turn_count")
    |> unique_ints
  in
  `Assoc
    [
      ( "requested_keeper_turn_id",
        match turn_id with Some value -> `Int value | None -> `Null );
      ("manifest_keeper_turn_ids", json_int_list manifest_keeper_turn_ids);
      ("receipt_turn_counts", json_int_list receipt_turn_counts);
      ("max_oas_turn_count", json_int_opt scan.max_oas_turn_count);
      ( "provider_lane_resolved_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_lane_resolved) );
      ( "provider_attempt_started_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_attempt_started) );
      ( "provider_attempt_finished_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Provider_attempt_finished) );
      ( "checkpoint_saved_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Checkpoint_saved) );
      ( "event_bus_correlated_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Event_bus_correlated) );
      ( "memory_injected_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Memory_injected) );
      ( "memory_flushed_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Memory_flushed) );
      ( "receipt_appended_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Receipt_appended) );
      ( "turn_finished_count",
        `Int
          (runtime_manifest_scan_event_count scan
             Keeper_runtime_manifest.Turn_finished) );
    ]

let keeper_runtime_trace_json (config : Coord.config) (name : string)
    ?trace_id ?turn_id ?(limit = 200) ()
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  if not (Keeper_config.validate_name name) then
    ( `Not_found,
      `Assoc
        [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ] )
  else
    let trace_id_query =
      match trace_id with
      | Some value when String.trim value <> "" -> Some (String.trim value)
      | _ -> None
    in
    let missing_trace_id_json =
      `Assoc
        [
          ( "error",
            `String
              (Printf.sprintf
                 "keeper %S not found and trace_id query param was not supplied"
                 name) );
        ]
    in
    let meta_read_failed_json msg =
      `Assoc
        [
          ("error_kind", `String "keeper_meta_read_failed");
          ( "error",
            `String
              (Printf.sprintf
                 "keeper %S metadata read failed while resolving runtime trace: %s"
                 name msg) );
        ]
    in
    let effective_trace_id =
      match trace_id_query with
      | Some value -> Ok value
      | None -> (
          match Keeper_types.read_meta_resolved config name with
          | Ok (Some (_, meta)) ->
              Ok (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          | Ok None -> Error missing_trace_id_json
          | Error msg -> Error (meta_read_failed_json msg))
    in
    match effective_trace_id with
    | Error json -> (`Not_found, json)
    | Ok trace_id ->
        let limit = max 1 (min 500 limit) in
        let manifest_scan =
          read_runtime_manifest_scan ~config ~keeper_name:name ~trace_id
            ?turn_id ~limit ()
        in
        let manifest_rows = queue_to_list manifest_scan.returned_rows in
        let receipt_paths =
          manifest_rows
          |> List.map (fun row -> row.Keeper_runtime_manifest.links.receipt_path)
          |> unique_present_paths
        in
        let checkpoint_paths =
          manifest_rows
          |> List.map (fun row -> row.Keeper_runtime_manifest.links.checkpoint_path)
          |> unique_present_paths
        in
        let tool_call_log_paths =
          manifest_rows
          |> List.map (fun row ->
               row.Keeper_runtime_manifest.links.tool_call_log_path)
          |> unique_present_paths
        in
        let receipts =
          read_receipt_rows ~keeper_name:name ~trace_id ?turn_id receipt_paths
          |> take_last limit
        in
        let selected_turn_id = selected_keeper_turn_id ?turn_id manifest_scan in
        let selected_terminal_event_present =
          terminal_event_present_for_turn
            ?keeper_turn_id:selected_turn_id
            manifest_scan
        in
        let health, stale_reason =
          if manifest_scan.total_rows = 0 then ("empty", Some "no_manifest_rows")
          else if not selected_terminal_event_present then
            ("incomplete", Some "missing_turn_finished")
          else if receipts = [] then ("partial", Some "no_matching_receipt_rows")
          else ("ok", None)
        in
        ( `OK,
          `Assoc
            [
              ("keeper", `String name);
              ( "trace_id",
                `String trace_id );
              ( "turn_id",
                match turn_id with
                | Some value -> `Int value
                | None -> `Null );
              ("manifest_path", `String manifest_scan.path);
              ("manifest_path_present", `Bool (Fs_compat.file_exists manifest_scan.path));
              ("manifest_total_rows", `Int manifest_scan.total_rows);
              ("manifest_returned_rows", `Int (List.length manifest_rows));
              ("receipt_returned_rows", `Int (List.length receipts));
              ( "turn_identity",
                turn_identity_summary_json ?turn_id manifest_scan receipts );
              ("provider_attempts", provider_attempts_summary_json manifest_scan);
              ("event_bus", event_bus_summary_json manifest_scan);
              ("memory", memory_summary_json manifest_scan);
              ( "runtime_lens",
                runtime_lens_json ~trace_id ?turn_id manifest_scan );
              ("health", `String health);
              ( "stale_reason",
                match stale_reason with
                | Some value -> `String value
                | None -> `Null );
              ( "linked_artifacts",
                `Assoc
                  [
                    ( "receipts",
                      `List
                        (List.map
                           (linked_artifact_json ~kind:"execution_receipt")
                           receipt_paths) );
                    ( "checkpoints",
                      `List
                        (List.map
                           (linked_artifact_json ~kind:"oas_checkpoint")
                           checkpoint_paths) );
                    ( "tool_call_logs",
                      `List
                        (List.map
                           (linked_artifact_json ~kind:"tool_call_log")
                           tool_call_log_paths) );
                  ] );
              ( "manifest_rows",
                `List (List.map runtime_manifest_public_json manifest_rows) );
              ("receipts", `List (List.map runtime_trace_public_json receipts));
            ] )

let handle_keeper_checkpoints_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_suffix req_path keeper_suffix_checkpoints in
  if String.length name = 0 then
    Http.Response.json ~status:`Bad_request
      {|{"ok":false,"error":"keeper name is required"}|} reqd
  else
    let config = state.Mcp_server.room_config in
    try
      let args = Yojson.Safe.from_string body_str in
      let action = Safe_ops.json_string ~default:"" "action" args in
      match action with
      | "delete_history" ->
          let snapshot_ids =
            Safe_ops.json_string_list "snapshot_ids" args
            |> List.map String.trim
            |> List.filter (fun value -> value <> "")
            |> Json_util.dedupe_keep_order
          in
          if snapshot_ids = [] then
            Http.Response.json ~status:`Bad_request
              {|{"ok":false,"error":"snapshot_ids is required"}|} reqd
          else
            let trace_id_result =
              match Keeper_types.read_meta_resolved config name with
              | Ok (Some (_, meta)) ->
                  Ok (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
              | Ok None ->
                  Error (Printf.sprintf "keeper %S not found" name)
              | Error msg -> Error msg
            in
            (match trace_id_result with
             | Error msg ->
                 Http.Response.json ~status:`Not_found
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped msg))
                   reqd
             | Ok trace_id ->
                 let session_dir = Keeper_types.keeper_session_dir config trace_id in
                 let (deleted, missing) =
                   Keeper_checkpoint_store.delete_oas_history_files
                     ~session_dir ~snapshot_ids
                 in
                 let (_status, inventory) =
                   keeper_checkpoint_inventory_json config name
                 in
                 Http.Response.json ~compress:true ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc
                         [
                           ("ok", `Bool true);
                           ("action", `String "delete_history");
                           ("keeper", `String name);
                           ("deleted_snapshot_ids", `List (List.map (fun id -> `String id) deleted));
                           ("missing_snapshot_ids", `List (List.map (fun id -> `String id) missing));
                           ("inventory", inventory);
                         ]))
                   reqd)
      | "" ->
          Http.Response.json ~status:`Bad_request
            {|{"ok":false,"error":"action is required"}|} reqd
      | other ->
          Http.Response.json ~status:`Bad_request
            (Printf.sprintf {|{"ok":false,"error":"unknown action: %s"}|}
               (String.escaped other))
            reqd
    with
    | Yojson.Json_error e ->
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"ok":false,"error":"invalid json: %s"}|}
             (String.escaped e))
          reqd

let is_valid_keeper_name name =
  String.length name > 0
  && String.length name <= 128
  && String.to_seq name
     |> Seq.for_all (fun c ->
          (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c = '_' || c = '-')

let extract_keeper_name_for_post req_path suffix =
  let plen = String.length keeper_api_prefix in
  let slen = String.length suffix in
  let raw =
    String.trim
      (String.sub req_path plen (String.length req_path - plen - slen))
  in
  if is_valid_keeper_name raw then raw else ""

let refresh_keeper_execution_surfaces ~config ~name event =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  (try Dashboard_cache.invalidate "execution:default:light" with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Dashboard.warn
         "keeper %s %s: execution dashboard cache invalidate failed: %s"
         name event (Printexc.to_string exn));
  Server_dashboard_http_execution_surfaces.patch_keeper_dependent_caches
    ~keeper_name:name ~event

let invalidate_keeper_execution_surfaces ~config () =
  Operator_control_snapshot.invalidate_snapshot_cache ();
  Dashboard_projection_cache.invalidate_snapshot_json ~config;
  Server_dashboard_http_execution_surfaces.invalidate_execution_cache ()

let handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_config in
  if String.length name = 0 then
    Http.Response.json ~status:`Bad_request
      {|{"error":"keeper name is required"}|} reqd
  else
    let config = state.Mcp_server.room_config in
    match Keeper_types.read_meta config name with
    | Error msg ->
        Http.Response.json ~status:`Not_found
          (Printf.sprintf {|{"error":"%s"}|}
             (String.escaped msg))
          reqd
    | Ok None ->
        Http.Response.json ~status:`Not_found
          (Printf.sprintf {|{"error":"keeper %S not found"}|} name)
          reqd
    | Ok (Some meta0) ->
        (try
           let args = Yojson.Safe.from_string body_str in
           let fields_opt =
             match args with
             | `Assoc fields -> Some fields
             | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _
             | `String _ | `List _ ->
                 None
           in
           match fields_opt with
           | Some fields ->
               let body_name =
                 match List.assoc_opt "name" fields with
                 | Some (`String value) ->
                     let trimmed = String.trim value in
                     if trimmed = "" then None else Some trimmed
                 | _ -> None
               in
               if Option.is_some body_name
                  && body_name <> Some name
               then
                 Http.Response.json ~status:`Bad_request
                   (Printf.sprintf
                      {|{"error":"keeper name mismatch: route=%S body=%S"}|}
                      name (Option.value ~default:"" body_name))
                   reqd
               else
                 let args_with_name =
                   `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
                 in
                 let keeper_ctx : _ Tool_keeper.context =
                   {
                     config;
                     agent_name;
                     sw;
                     clock;
                     proc_mgr = state.Mcp_server.proc_mgr;
                     net = state.Mcp_server.net;
                   }
                 in
                 (match Keeper_turn_up_args.parse keeper_ctx args_with_name with
                 | Error (_ok, msg) ->
                     Http.Response.json ~status:`Bad_request
                       (Printf.sprintf {|{"error":"%s"}|}
                          (String.escaped msg))
                       reqd
                 | Ok parsed ->
                     let ok, msg =
                       Keeper_turn_up_update.update_keeper keeper_ctx parsed meta0
                     in
                     if not ok then
                       Http.Response.json ~status:`Bad_request
                         (Printf.sprintf {|{"error":"%s"}|}
                            (String.escaped msg))
                         reqd
                     else
                       let (_st, json) =
                         Dashboard_http_keeper.keeper_config_json config name
                       in
                       Http.Response.json ~compress:true ~request:req
                         (Yojson.Safe.to_string json) reqd)
           | None ->
               Http.Response.json ~status:`Bad_request
                 {|{"error":"request body must be a JSON object"}|}
                 reqd
         with Yojson.Json_error e ->
           Http.Response.json ~status:`Bad_request
             (Printf.sprintf {|{"error":"invalid json: %s"}|}
                (String.escaped e))
             reqd)

let handle_keeper_lifecycle_post ?body_str ~sw ~clock ~tool_name ~action
    state agent_name req reqd =
  let req_path = Http.Request.path req in
  let suffix_result =
    match action with
    | "boot" -> Ok keeper_suffix_boot
    | "shutdown" -> Ok keeper_suffix_shutdown
    | "reset" -> Ok keeper_suffix_reset
    | "clear" -> Ok keeper_suffix_clear
    | unknown ->
        Error (Printf.sprintf "unknown keeper lifecycle action: %s" unknown)
  in
  match suffix_result with
  | Error msg ->
      Http.Response.json ~status:`Bad_request
        (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg)) reqd
  | Ok suffix ->
  let name = extract_keeper_name_for_post req_path suffix in
  if String.length name = 0 then
    Http.Response.json ~status:`Bad_request
      {|{"error":"keeper name is required"}|} reqd
  else
    let config = state.Mcp_server.room_config in
    let resolve_keeper_agent_name () =
      match Keeper_registry.find_by_name name with
      | Some entry -> Some entry.meta.agent_name
      | None -> (
          match Keeper_types.read_meta config name with
          | Ok (Some meta) -> Some meta.agent_name
          | Ok None -> None
          | Error err ->
              Log.Keeper.warn
                "resolve_keeper_agent_name %s: read_meta failed: %s"
                name err;
              None)
    in
    let persist_keeper_paused_state paused =
      match Keeper_types.read_meta config name with
      | Ok (Some meta) when Bool.equal meta.paused paused -> ()
      | Ok (Some meta) ->
          let updated_meta =
            {
              meta with
              paused;
              updated_at = Keeper_types.now_iso ();
            }
          in
          (match Keeper_types.write_meta ~force:true config updated_meta with
           | Ok () -> ()
           | Error err ->
               Log.Keeper.warn
                 "keeper %s %s: write_meta failed: %s"
                 name
                 (if paused then "pause" else "resume")
                 err)
      (* Issue #8391 HIGH #1: split [Ok None] (meta vanished) from
         [Error _] (IO/parse failure) so silent failures become visible.
         The boot HTTP contract is unchanged — auto-resume cleanup is a
         best-effort side effect of [boot], not the primary action. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s %s: meta missing — skipping paused-state persist"
            name
            (if paused then "pause" else "resume");
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s %s: read_meta failed: %s"
            name
            (if paused then "pause" else "resume")
            err;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Paused_state_persist_phase.(to_label Boot_resume_persist));
                     ("reason", "read_meta_error")]
            ()
    in
    let resume_booted_keeper_if_needed () =
      match Keeper_types.read_meta config name with
      | Ok (Some meta) when meta.paused ->
          persist_keeper_paused_state false;
          (match resolve_keeper_agent_name () with
           | Some keeper_agent_name ->
               Keeper_keepalive.process_directive
                 ~agent_name:keeper_agent_name
                 "resume"
           | None ->
               Log.Keeper.warn
                 "keeper boot: agent_name not found for paused keeper %s"
                 name)
      | Ok (Some _) -> ()
      (* Issue #8391 HIGH #1: split [Ok None] from [Error _] — boot itself
         already succeeded via Tool_keeper.dispatch, so we don't change the
         HTTP status. We make the failure observable instead. *)
      | Ok None ->
          Log.Keeper.warn
            "keeper %s boot: meta missing — skipping auto-resume check"
            name;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s boot: read_meta failed during auto-resume check: %s"
            name
            err;
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", Paused_state_persist_phase.(to_label Boot_resume_check));
                     ("reason", "read_meta_error")]
            ()
    in
    let keeper_ctx : _ Tool_keeper.context =
      {
        config;
        agent_name;
        sw;
        clock;
        proc_mgr = state.Mcp_server.proc_mgr;
        net = state.Mcp_server.net;
      }
    in
    let args_result =
      match action with
      | "clear" -> (
          match body_str with
          | None ->
              Error "request body is required for clear"
          | Some raw -> (
              try
                let parsed = Yojson.Safe.from_string raw in
                match parsed with
                | `Assoc fields ->
                    Ok (`Assoc (("name", `String name) :: List.remove_assoc "name" fields))
                | _ ->
                    Error "request body must be a JSON object"
              with
              | Yojson.Json_error err ->
                  Error (Printf.sprintf "invalid json: %s" err)))
      | _ -> Ok (`Assoc [("name", `String name)])
    in
    match args_result with
    | Error msg ->
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
          reqd
    | Ok args ->
    match Tool_keeper.dispatch keeper_ctx ~name:tool_name ~args with
    | Some (true, body) when String.equal action "boot" || String.equal action "clear" ->
        if String.equal action "boot"
        then (
          resume_booted_keeper_if_needed ();
          refresh_keeper_execution_surfaces ~config ~name "started")
        else invalidate_keeper_execution_surfaces ~config ();
        Http.Response.json ~compress:true ~request:req
          (Printf.sprintf {|{"ok":true,"action":"%s","name":"%s","detail":%s}|}
             (String.escaped action)
             (String.escaped name)
             body)
          reqd
    | Some (true, _body) ->
        (match action with
         | "shutdown" -> refresh_keeper_execution_surfaces ~config ~name "stopped"
         | _ -> invalidate_keeper_execution_surfaces ~config ());
        Http.Response.json ~compress:true ~request:req
          (Printf.sprintf {|{"ok":true,"action":"%s","name":"%s"}|}
             (String.escaped action)
             (String.escaped name))
          reqd
    | Some (false, body) ->
        Http.Response.json ~status:`Bad_request ~request:req
          (Yojson.Safe.to_string
             (`Assoc [("ok", `Bool false); ("error", `String body)]))
          reqd
    | None ->
        Http.Response.json ~status:`Internal_server_error ~request:req
          {|{"ok":false,"error":"dispatch returned None"}|}
          reqd

(** POST /api/v1/keepers/:name/directive — pause / resume / wakeup.

    Delegates to [Keeper_keepalive.process_directive] which updates
    registry state, dispatches a state-machine event, and optionally
    wakes up the keeper fiber. *)
let handle_keeper_directive_post state _agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_directive in
  if String.length name = 0 then
    Http.Response.json ~status:`Bad_request
      {|{"error":"keeper name is required"}|} reqd
  else
    let action =
      try
        let json = Yojson.Safe.from_string body_str in
        match Safe_ops.json_string_opt "action" json with
        | Some a when a = "pause" || a = "resume" || a = "wakeup" -> Ok a
        | Some a ->
            Error
              (Printf.sprintf
                 "invalid action %S: expected pause, resume, or wakeup" a)
        | None -> Error "missing \"action\" field"
      with Yojson.Json_error e ->
        Error (Printf.sprintf "invalid json: %s" (String.escaped e))
    in
    match action with
    | Error msg ->
        Http.Response.json ~status:`Bad_request
          (Printf.sprintf {|{"ok":false,"error":%s}|}
             (Yojson.Safe.to_string (`String msg)))
          reqd
    | Ok action_str ->
        let config = state.Mcp_server.room_config in
        (* Issue #8391 HIGH #1: split [Ok None] (meta vanished) from [Error _]
           (IO/parse failure). For pause/resume the operator expects state to
           change; silent 200 hides the failure. For wakeup we preserve the
           prior best-effort semantics (wakeup does not require meta). *)
        let read_result = Keeper_types.read_meta config name in
        let meta_opt =
          match read_result with
          | Ok (Some meta) -> Some meta
          | Ok None -> None
          | Error err ->
              Log.Keeper.warn "directive %s %s: read_meta failed: %s"
                action_str name err;
              None
        in
        let persist_paused_state paused =
          match meta_opt with
          | Some meta when not (Bool.equal meta.paused paused) ->
              let updated_meta =
                {
                  meta with
                  paused;
                  updated_at = Keeper_types.now_iso ();
                }
              in
              (match Keeper_types.write_meta ~force:true config updated_meta with
               | Ok () -> ()
               | Error err ->
                   Log.Keeper.warn
                     "directive %s: write_meta failed for %s: %s"
                     action_str
                     name
                     err)
          | Some _ | None -> ()
        in
        let proceed () =
          (* #10583: pause was missing from the first match, falling
             through to the [_] arm and emitting a false
             "Unknown keeper directive: pause" WARN even though the
             second match (line 923) handles pause correctly. The
             persisted paused=true also was not reaching meta.json
             because persist_paused_state(true) was never called for
             the pause action. Adding the case here both removes the
             false WARN and restores meta-side durability so the next
             server restart preserves the operator's pause decision. *)
          (match action_str with
           | "pause" -> persist_paused_state true
           | "resume" -> persist_paused_state false
           | "wakeup" -> ()
           | _ ->
               Log.Server.warn "Unknown keeper directive: %s" action_str);
          let resolved_agent_name =
            match Keeper_registry.find_by_name name with
            | Some entry -> entry.meta.agent_name
            | None -> (
                match meta_opt with
                | Some meta -> meta.agent_name
                | None -> Keeper_types.keeper_agent_name name)
          in
          Keeper_keepalive.process_directive
            ~agent_name:resolved_agent_name action_str;
          (match action_str with
           | "pause" -> refresh_keeper_execution_surfaces ~config ~name "paused"
           | "resume" -> refresh_keeper_execution_surfaces ~config ~name "resumed"
           | "wakeup" -> invalidate_keeper_execution_surfaces ~config ()
           | _ -> invalidate_keeper_execution_surfaces ~config ());
          Http.Response.json ~compress:true ~request:req
            (Printf.sprintf {|{"ok":true,"action":"%s","name":"%s"}|}
               (String.escaped action_str) (String.escaped name))
            reqd
        in
        let needs_meta_for_state_transition =
          match action_str with
          | "pause" | "resume" -> true
          | _ -> false
        in
        (match read_result, needs_meta_for_state_transition with
         | Error err, true ->
             Log.Keeper.error
               "directive %s: read_meta failed for %s: %s"
               action_str
               name
               err;
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_paused_state_persist_errors
               ~labels:[("phase", Paused_state_persist_phase.(to_label Directive));
                        ("reason", "read_meta_error")]
               ();
             Http.Response.json ~status:`Internal_server_error ~request:req
               (Printf.sprintf
                  {|{"ok":false,"action":"%s","name":"%s","error":"read_meta failed: %s"}|}
                  (String.escaped action_str)
                  (String.escaped name)
                  (String.escaped err))
               reqd
         | Ok None, true ->
             Log.Keeper.warn
               "directive %s: keeper meta missing for %s — refusing silent no-op"
               action_str
               name;
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_paused_state_persist_errors
               ~labels:[("phase", Paused_state_persist_phase.(to_label Directive));
                        ("reason", "meta_missing")]
               ();
             Http.Response.json ~status:`Not_found ~request:req
               (Printf.sprintf
                  {|{"ok":false,"action":"%s","name":"%s","error":"keeper meta not found"}|}
                  (String.escaped action_str)
                  (String.escaped name))
               reqd
         | Error err, false ->
             (* Wakeup does not require meta; log but proceed. *)
             Log.Keeper.warn
               "directive %s: read_meta failed for %s (best-effort proceed): %s"
               action_str
               name
               err;
             proceed ()
         | Ok None, false
         | Ok (Some _), _ ->
             proceed ())

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory.
    Called from prefix_get "/api/v1/keepers/" in the main routing file. *)
let handle_keeper_get_subroutes state req request reqd =
  let req_path = Http.Request.path req in
  let prefix = keeper_api_prefix in
  let plen = String.length prefix in
  let tlen = String.length req_path in
  let ends_with suffix =
    let slen = String.length suffix in
    tlen > plen + slen
    && String.sub req_path (tlen - slen) slen = suffix
  in
  let extract_name suffix =
    let slen = String.length suffix in
    String.trim (String.sub req_path plen (tlen - plen - slen))
  in
  if ends_with "/chat/history" then
    let name = extract_name "/chat/history" in
    if name = "" then
      Server_auth.respond_json_with_cors ~status:`Bad_request request reqd
        {|{"error":"missing keeper name"}|}
    else
      let base_dir = state.Mcp_server.room_config.base_path in
      let messages =
        Keeper_chat_store.load ~base_dir ~keeper_name:name
      in
      Server_auth.respond_json_with_cors ~status:`OK request reqd
        (Yojson.Safe.to_string (Keeper_chat_store.to_json_array messages))
  else if ends_with keeper_suffix_checkpoints then
    let name = extract_name keeper_suffix_checkpoints in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let (st, json) = keeper_checkpoint_inventory_json state.Mcp_server.room_config name in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json ~status ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with keeper_suffix_runtime_trace then
    let name = extract_name keeper_suffix_runtime_trace in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let trace_id = Server_utils.query_param req "trace_id" in
      let turn_id =
        match Server_utils.query_param req "turn_id" with
        | Some raw -> int_of_string_opt (String.trim raw)
        | None -> None
      in
      let limit =
        Server_utils.int_query_param req "limit" ~default:200
        |> max 1 |> min 500
      in
      let st, json =
        keeper_runtime_trace_json state.Mcp_server.room_config name
          ?trace_id ?turn_id ~limit ()
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json ~status ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/config" then
    let name = extract_name "/config" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let config = state.Mcp_server.room_config in
      let (st, json) =
        Dashboard_http_keeper.keeper_config_json config name
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json ~status ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with keeper_suffix_bdi_snapshot then
    let name = extract_name keeper_suffix_bdi_snapshot in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let config = state.Mcp_server.room_config in
      let (st, json) =
        Dashboard_http_keeper.keeper_bdi_snapshot_json config name
      in
      let status : Httpun.Status.t =
        match st with `OK -> `OK | `Not_found -> `Not_found
      in
      Http.Response.json ~status ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/tool-stats" then
    let name = extract_name "/tool-stats" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else if not (Keeper_config.validate_name name) then
      Http.Response.json ~status:`Bad_request
        (Yojson.Safe.to_string
           (`Assoc [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])) reqd
    else
      let config = state.Mcp_server.room_config in
      let masc_root = Coord.masc_root_dir config in
      let window_hours =
        Server_utils.int_query_param req "window_hours"
          ~default:24
        |> max 1 |> min 168  (* 1h .. 7d *)
      in
      let since = Time_compat.now () -. (float_of_int window_hours *. 3600.0) in
      let read_result =
        Trajectory.read_entries_since_result ~masc_root ~keeper_name:name ~since
      in
      let entries = read_result.Trajectory.entries in
      let tools = Trajectory.aggregate_tool_stats entries in
      let timeline = Trajectory.hourly_timeline entries in
      let latest_ts =
        List.fold_left
          (fun acc (entry : Trajectory.tool_call_entry) ->
            match acc with
            | Some ts when ts >= entry.ts -> acc
            | _ -> Some entry.ts)
          None entries
      in
      let latest_age_s =
        match latest_ts with
        | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
        | None -> None
      in
      let freshness_slo_s = 300.0 in
      let dashboard_surface = "/api/v1/keepers/:name/tool-stats" in
      let coverage_gaps =
        Telemetry_coverage_gap.read_recent ~masc_root ~n:32
        |> List.filter (fun gap ->
             String.equal
               (Safe_ops.json_string ~default:"" "dashboard_surface" gap)
               dashboard_surface
             &&
             match Safe_ops.json_string_opt "keeper_name" gap with
             | Some keeper_name -> String.equal keeper_name name
             | None -> true)
      in
      let latest_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
      let health, stale_reason =
        match latest_gap with
        | Some gap ->
            ( "coverage_gap",
              Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
        | None -> (
            match latest_age_s with
            | None -> ("empty", "no_entries")
            | Some age when age > freshness_slo_s ->
                ("stale", "freshness_slo_exceeded")
            | Some _ -> ("ok", ""))
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("window_hours", `Int window_hours);
        ("total_entries", `Int (List.length entries));
        ("source", `String "trajectory_tool_call");
        ( "producer",
          `String
            "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
        ("durable_store", `String (Trajectory.trajectories_dir masc_root name));
        ("dashboard_surface", `String dashboard_surface);
        ("freshness_slo_s", `Float freshness_slo_s);
        ( "latest_ts_unix",
          match latest_ts with Some ts -> `Float ts | None -> `Null );
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ( "latest_age_s",
          match latest_age_s with Some age -> `Float age | None -> `Null );
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ( "gate_decode",
          `Assoc
            [
              ( "parsed_gate_count",
                `Int read_result.Trajectory.gate_decode.parsed_gate_count );
              ( "legacy_default_count",
                `Int read_result.Trajectory.gate_decode.legacy_default_count );
            ] );
        ("coverage_gaps", `List coverage_gaps);
        ("tools", `List (List.map Trajectory.tool_stat_to_json tools));
        ("timeline", `List (List.map Trajectory.hourly_bucket_to_json timeline));
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/tool-calls" then
    let name = extract_name "/tool-calls" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else if not (Keeper_config.validate_name name) then
      Http.Response.json ~status:`Bad_request
        (Yojson.Safe.to_string
           (`Assoc [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])) reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min 200
      in
      let entries =
        Keeper_tool_call_log.read_recent ~keeper_name:name ~n:limit ()
      in
      let config = state.Mcp_server.room_config in
      let masc_root = Coord.masc_root_dir config in
      let latest_ts =
        List.fold_left
          (fun acc json ->
            match Safe_ops.json_float_opt "ts" json with
            | Some ts -> (
                match acc with
                | Some existing when existing >= ts -> acc
                | _ -> Some ts)
            | None -> acc)
          None entries
      in
      let freshness_slo_s = 300.0 in
      let dashboard_surface = "/api/v1/keepers/:name/tool-calls" in
      let latest_age_s =
        match latest_ts with
        | Some ts -> Some (max 0.0 (Time_compat.now () -. ts))
        | None -> None
      in
      let coverage_gaps =
        Telemetry_coverage_gap.read_recent ~masc_root ~n:32
        |> List.filter (fun gap ->
             String.equal "tool_call_io"
               (Safe_ops.json_string ~default:"" "source" gap)
             &&
             match Safe_ops.json_string_opt "keeper_name" gap with
             | Some keeper_name -> String.equal keeper_name name
             | None -> true)
      in
      let latest_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
      let health, stale_reason =
        match latest_gap with
        | Some gap ->
          ( "coverage_gap",
            Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
        | None -> (
            match latest_age_s with
            | None -> ("empty", "no_entries")
            | Some age when age > freshness_slo_s ->
                ("stale", "freshness_slo_exceeded")
            | Some _ -> ("ok", ""))
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length entries));
        ("source", `String "tool_call_io");
        ( "producer",
          `String
            "keeper_hooks_oas.post_tool_use|mcp_server_eio_call_tool.runtime_mcp" );
        ("durable_store", `String (Filename.concat masc_root "tool_calls"));
        ("dashboard_surface", `String dashboard_surface);
        ("freshness_slo_s", `Float freshness_slo_s);
        ( "latest_ts_unix",
          match latest_ts with Some ts -> `Float ts | None -> `Null );
        ( "latest_ts_iso",
          match latest_ts with
          | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
          | None -> `Null );
        ( "latest_age_s",
          match latest_age_s with Some age -> `Float age | None -> `Null );
        ("health", `String health);
        ( "stale_reason",
          if stale_reason = "" then `Null else `String stale_reason );
        ("coverage_gaps", `List coverage_gaps);
        ("entries", `List entries);
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/trajectory" then
    let name = extract_name "/trajectory" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else if not (Keeper_config.validate_name name) then
      Http.Response.json ~status:`Bad_request
        (Yojson.Safe.to_string
           (`Assoc [("error", `String (Printf.sprintf "invalid keeper name: %s" name))])) reqd
    else
      let config = state.Mcp_server.room_config in
      (match Keeper_types.read_meta config name with
       | Error e ->
         Http.Response.json ~status:`Internal_server_error
           (Printf.sprintf {|{"error":"%s"}|} (String.escaped e)) reqd
       | Ok None ->
         Http.Response.json ~status:`Not_found
           (Printf.sprintf {|{"error":"keeper %S not found"}|} name) reqd
       | Ok (Some m) ->
         let trajectory_default_limit = 50 in
         let trajectory_max_limit = 500 in
         let trace_id =
           Keeper_id.Trace_id.to_string m.runtime.trace_id
         in
         let limit =
           Server_utils.int_query_param req "limit"
             ~default:trajectory_default_limit
           |> max 1 |> min trajectory_max_limit
         in
         (* Allow caller to request more result text up to a safe max.
            Default 2000 chars is enough for the collapsed list view;
            set result_max_len=10000 (or higher, capped at 10000) to
            get full detail for an expanded entry. *)
         let result_max_len =
           Server_utils.int_query_param req "result_max_len"
             ~default:2000
           |> max 0 |> min 10000
         in
         let content_max_len =
           Server_utils.int_query_param req "content_max_len"
             ~default:Trajectory.default_thinking_truncation
           |> max 0 |> min 50000
         in
         let include_thinking =
           Server_utils.bool_query_param req "include_thinking"
             ~default:false
         in
         let masc_root = Coord.masc_root_dir config in
         let trajectory_lines =
           Trajectory.read_all_lines ~masc_root ~keeper_name:m.name
             ~trace_id
         in
         let all_lines =
           if include_thinking then
             merge_keeper_trace_lines ~config ~trace_id trajectory_lines
           else
             trajectory_lines
         in
         (* Filter out thinking entries if not requested *)
         let lines =
           if include_thinking then all_lines
           else List.filter (function
             | Trajectory.Tool_call _ -> true
             | Trajectory.Thinking _ -> false) all_lines
         in
         let total = List.length lines in
         let recent =
           if total <= limit then lines
           else
             let drop = total - limit in
             List.filteri (fun i _e -> i >= drop) lines
         in
         let json = `Assoc [
           ("keeper", `String name);
           ("trace_id", `String trace_id);
           ("generation", `Int m.runtime.generation);
           ("total_entries", `Int total);
           ("showing", `Int (List.length recent));
           ("entries", `List (List.map
             (Trajectory.trajectory_line_to_json ~result_max_len ~content_max_len) recent));
         ] in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd)
  else if ends_with "/transitions" then
    let name = extract_name "/transitions" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:20
        |> max 1 |> min 50
      in
      let base_path = state.Mcp_server.room_config.base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let phase_str = match phase with
        | Some p -> `String (Keeper_state_machine.phase_to_string p)
        | None -> `Null
      in
      let transitions =
        Keeper_transition_audit.recent_transitions_json
          ~keeper_name:name ~limit
      in
      let json = `Assoc [
        "keeper", `String name;
        "current_phase", phase_str;
        "count", `Int (match transitions with `List l -> List.length l | _ -> 0);
        "transitions", transitions;
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  (* #12798 Dashboard Gaps: lifecycle event timeline per keeper. *)
  else if ends_with "/lifecycle" then
    let name = extract_name "/lifecycle" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let limit =
        Server_utils.int_query_param req "limit" ~default:50
        |> max 1 |> min 200
      in
      let events =
        Keeper_lifecycle_audit.recent_json ~keeper_name:name ~limit
      in
      let json = `Assoc [
        "keeper", `String name;
        "count", `Int (match events with `List l -> List.length l | _ -> 0);
        "events", events;
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/eval" then
    let name = extract_name "/eval" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let base_path = state.Mcp_server.room_config.base_path in
      let limit =
        Server_utils.int_query_param req "limit" ~default:10
        |> max 1 |> min 100
      in
      (* Use keeper name as agent_name for eval lookup.
         Keepers may also have a separate agent_name — look up both. *)
      let config = state.Mcp_server.room_config in
      let agent_name_opt =
        match Keeper_types.read_meta config name with
        | Ok (Some m) when m.agent_name <> name -> Some m.agent_name
        | _ -> None
      in
      let snapshots_by_name =
        Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
      in
      let snapshots =
        match agent_name_opt with
        | Some agent_name when snapshots_by_name = [] ->
            Dashboard_eval_feed.read_latest ~base_path ~agent_name ~limit
        | _ -> snapshots_by_name
      in
      let latest_verdict =
        match snapshots with
        | s :: _ -> Some s.Dashboard_eval_feed.verdict
        | [] -> None
      in
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length snapshots));
        ("latest_coverage",
          match latest_verdict with
          | Some v -> `Float v.Dashboard_eval_feed.coverage
          | None -> `Null);
        ("latest_all_passed",
          match latest_verdict with
          | Some v -> `Bool v.Dashboard_eval_feed.all_passed
          | None -> `Null);
        ("snapshots",
          `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots));
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if ends_with "/state-diagram" then
    let name = extract_name "/state-diagram" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let base_path = state.Mcp_server.room_config.base_path in
      let phase = Keeper_registry.get_phase ~base_path name in
      let current = match phase with Some p -> p | None -> Keeper_state_machine.Offline in
      let mermaid = Keeper_state_machine.phase_to_mermaid ~current in
      let phase_str = Keeper_state_machine.phase_to_string current in
      let stats = Thompson_sampling.get_stats name in
      let meta = Keeper_types.read_meta
          state.Mcp_server.room_config name in
      let tool_count = match meta with
        | Ok (Some m) ->
          List.length (Keeper_exec_tools.keeper_allowed_tool_names m)
        | _ -> 0
      in
      let recovery_floor_count =
        List.length (Keeper_tool_policy.failing_minimum_tool_names ())
      in
      let turn_outcome : [`Ok | `Failed] option =
        match Keeper_registry.get ~base_path:state.Mcp_server.room_config.base_path name with
        | Some entry when entry.turn_consecutive_failures > 0 ->
          Some `Failed
        | Some _ -> Some `Ok
        | None -> None
      in
      let decision_pipeline_mermaid =
        Keeper_decision_audit.decision_pipeline_to_mermaid
          ?turn_outcome
          ~guard_penalty_total:stats.guard_penalties_total
          ~phase:current
          ~thompson_alpha:stats.alpha
          ~thompson_beta:stats.beta
          ~tool_count
          ~recovery_floor_count
          ()
      in
      let cascade_fsm_mermaid =
        match meta with
        | Ok (Some m) ->
          let routing =
            Keeper_cascade_routing.select_cascade
              ~base_cascade:(Keeper_types.cascade_name_of_meta m) ~phase:current
          in
          let models = [ "candidate" ] in
          let provider_health = [] in
          (* Slot occupancy from the local runtime pool. The cascade FSM
             shares these slots across all keepers, so rendering the
             fleet-global (used, capacity) is the honest value — a
             per-cascade split would claim an isolation the runtime does
             not actually provide. *)
          let slot_state =
            let used = Local_runtime_pool.allocated_slots () in
            let max = Local_runtime_pool.configured_capacity () in
            if max > 0 then Some (used, max) else None
          in
          Keeper_decision_audit.cascade_fsm_to_mermaid
            ~provider_health
            ?slot_state
            ~effective_cascade_reason:routing.reason
            ~models ~last_provider_result:None ()
        | _ ->
          Keeper_decision_audit.cascade_fsm_to_mermaid
            ~models:[] ~last_provider_result:None ()
      in
      let cascade_models = [] in
      let last_provider = `Null in
      (* Memory tier usage: join kind_caps (policy) with kind_counts (bank
         summary). Each kind reports used / cap so the dashboard tier
         panel can render saturation without re-reading the memory file. *)
      let memory_kind_usage : Yojson.Safe.t =
        let caps = Keeper_memory_policy.kind_caps () in
        let used_by_kind =
          match meta with
          | Ok (Some _) ->
            (try
              let summary =
                Keeper_memory.read_keeper_memory_summary
                  state.Mcp_server.room_config
                  ~name ~max_bytes:120_000 ~max_lines:200 ~recent_limit:0
              in
              summary.Keeper_memory.kind_counts
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> [])
          | _ -> []
        in
        let lookup_used k =
          List.assoc_opt k used_by_kind |> Option.value ~default:0
        in
        `List (List.map (fun (kind, cap) ->
          `Assoc [
            "kind", `String kind;
            "used", `Int (lookup_used kind);
            "cap", `Int cap;
            "priority", `Int (Keeper_memory_policy.priority_for_kind ~kind);
          ]) caps)
      in
      (* Compaction sub-FSM: only emit a diagram when the keeper is in
         the [Compacting] phase. The three nodes mirror
         [specs/bug-models/MemoryCompaction.tla]. *)
      let compaction_submachine_mermaid =
        match current with
        | Keeper_state_machine.Compacting ->
          let b = Buffer.create 256 in
          Buffer.add_string b "stateDiagram-v2\n";
          Buffer.add_string b "    [*] --> Accumulating\n";
          Buffer.add_string b "    Accumulating --> Compacting: ratio_gate\n";
          Buffer.add_string b "    Compacting --> Done: Compaction_completed\n";
          Buffer.add_string b "    Compacting --> Accumulating: Compaction_failed\n";
          Buffer.add_string b "    Done --> [*]\n";
          Buffer.add_string b
            "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
          Buffer.add_string b "    class Compacting active\n";
          `String (Buffer.contents b)
        | _ -> `Null
      in
      let json = `Assoc [
        "keeper", `String name;
        "current_phase", `String phase_str;
        "mermaid", `String mermaid;
        "decision_pipeline_mermaid", `String decision_pipeline_mermaid;
        "cascade_fsm_mermaid", `String cascade_fsm_mermaid;
        "compaction_submachine_mermaid", compaction_submachine_mermaid;
        "thompson_alpha", `Float stats.alpha;
        "thompson_beta", `Float stats.beta;
        "tool_count", `Int tool_count;
        "recovery_floor_count", `Int recovery_floor_count;
        "cascade_models", `List (List.map (fun s -> `String s) cascade_models);
        "last_provider_result", last_provider;
        "memory_kind_usage", memory_kind_usage;
      ] in
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string json) reqd
  else if req_path = prefix ^ "composite" then
    (* LT-16a: fleet-wide composite snapshot. Enumerates every
       registered keeper via [Keeper_registry.all] and projects each
       through [Keeper_composite_observer.observe]. Same purity
       contract as the per-keeper route below.

       Shape:
         { "generated_at": 1234567890.1,
           "count": 3,
           "snapshots": [ <snapshot JSON>, ... ] }

       Consumed by [dashboard/src/components/fleet-fsm-matrix.ts]
       (LT-16b, upcoming). *)
    let json =
      Server_dashboard_http.dashboard_fleet_composite_json
        ~config:state.Mcp_server.room_config ()
    in
    Http.Response.json ~compress:true ~request:req
      (Yojson.Safe.to_string json) reqd
  else if ends_with "/composite" then
    (* RFC-0003 §7: composite lifecycle snapshot derived from the
       registry entry via the [Keeper_composite_observer] pure
       projection. No mutation, no I/O, no provider/token access. *)
    let name = extract_name "/composite" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let base_path = state.Mcp_server.room_config.base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         Http.Response.json ~status:`Not_found
           (Printf.sprintf {|{"error":"keeper %S not registered"}|} name) reqd
       | Some entry ->
         let json =
           Server_dashboard_http.dashboard_keeper_composite_json
             ~config:state.Mcp_server.room_config entry
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd)
  else if req_path = prefix ^ "regime" then
    (* 7th FSM axis MVP: fleet-wide behavioral-regime snapshot. Same
       purity contract as the composite route above, uses the
       [Keeper_behavioral_regime_observer] pure projection. *)
    let base_path = state.Mcp_server.room_config.base_path in
    let snapshots =
      Keeper_behavioral_regime_observer.all_snapshots ~base_path ()
    in
    let json =
      `Assoc [
        "generated_at", `Float (Unix.gettimeofday ());
        "count", `Int (List.length snapshots);
        "snapshots",
          `List
            (List.map
               Keeper_behavioral_regime_observer.snapshot_to_json
               snapshots);
      ]
    in
    Http.Response.json ~compress:true ~request:req
      (Yojson.Safe.to_string json) reqd
  else if ends_with "/regime" then
    (* Per-keeper behavioral-regime snapshot. *)
    let name = extract_name "/regime" in
    if String.length name = 0 then
      Http.Response.json ~status:`Bad_request
        {|{"error":"keeper name is required"}|} reqd
    else
      let base_path = state.Mcp_server.room_config.base_path in
      (match Keeper_registry.get ~base_path name with
       | None ->
         Http.Response.json ~status:`Not_found
           (Printf.sprintf {|{"error":"keeper %S not registered"}|} name) reqd
       | Some entry ->
         let snapshot =
           Keeper_behavioral_regime_observer.observe entry
         in
         let json =
           Keeper_behavioral_regime_observer.snapshot_to_json snapshot
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd)
  else
    Http.Response.json ~status:`Not_found
      {|{"error":"not found"}|} reqd
