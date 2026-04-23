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
let keeper_suffix_directive = "/directive"

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
  Fs_compat.load_jsonl path
  |> List.filter_map internal_history_json_to_trajectory_line

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
  let masc_count =
    List.length
      (List.filter (fun name -> String.starts_with ~prefix:"masc_" name) allowed)
  in
  let tool_preset = Keeper_types.tool_access_preset meta.tool_access in
  let tool_also_allow = Keeper_types.tool_access_also_allowlist meta.tool_access in
  let tool_custom_allowlist =
    Keeper_types.tool_access_custom_allowlist meta.tool_access
    |> Option.value ~default:[]
  in
  `Assoc
    [
      ("ok", `Bool true);
      ("tool_access", Keeper_types.tool_access_to_json meta.tool_access);
      ( "tool_policy_mode",
        `String
          (match Keeper_types.tool_access_custom_allowlist meta.tool_access with
           | Some _ -> "custom"
           | None -> "preset") );
      ( "tool_preset",
        match tool_preset with
        | Some preset -> `String (Keeper_types.tool_preset_to_string preset)
        | None -> `Null );
      ("tool_also_allow", `List (List.map (fun s -> `String s) tool_also_allow));
      ("tool_custom_allowlist", `List (List.map (fun s -> `String s) tool_custom_allowlist));
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
                   let mode = Safe_ops.json_string ~default:"" "mode" args in
                   let preset_raw = Safe_ops.json_string_opt "preset" args in
                   let allow_present =
                     match Yojson.Safe.Util.member "allow" args with
                     | `Null -> false
                     | _ -> true
                   in
                   let allow = Safe_ops.json_string_list "allow" args |> dedupe_tool_names in
                   let also_allow =
                     Safe_ops.json_string_list "also_allow" args |> dedupe_tool_names
                   in
                   let deny =
                     Safe_ops.json_string_list "deny" args |> dedupe_tool_names
                   in
                   let tool_access_result =
                     match mode with
                     | "preset" -> (
                         match preset_raw with
                         | None -> Error "preset required when mode=preset"
                         | Some raw -> (
                             match Keeper_types.tool_preset_of_string raw with
                             | None ->
                                 Error
                                   (Printf.sprintf
                                      "invalid tool_preset '%s' (allowed: %s)"
                                      raw
                                      (String.concat
                                         ", "
                                         Keeper_types.valid_tool_preset_strings))
                             | Some preset ->
                                 Ok
                                   (Keeper_types.Preset
                                      { preset; also_allow })))
                    | "custom" ->
                        if not allow_present then
                          Error "allow required when mode=custom"
                        else
                        Ok (Keeper_types.Custom allow)
                     | "full" ->
                         Ok
                           (Keeper_types.Preset
                              { preset = Keeper_types.Full; also_allow = [] })
                     | "" ->
                         Error "mode required (preset|custom|full)"
                     | other ->
                         Error (Printf.sprintf "unknown mode: %s" other)
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
  let prefix = keeper_api_prefix in
  let plen = String.length prefix in
  let tlen = String.length req_path in
  let ends_with suffix =
    let slen = String.length suffix in
    tlen > plen + slen
    && String.sub req_path 0 plen = prefix
    && String.sub req_path (tlen - slen) slen = suffix
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
  let prefix = keeper_api_prefix in
  let plen = String.length prefix in
  let tlen = String.length req_path in
  let slen = String.length suffix in
  tlen > plen + slen
  && String.sub req_path 0 plen = prefix
  && String.sub req_path (tlen - slen) slen = suffix

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

let latest_preview_of_messages (messages : Oas.Types.message list) =
  messages
  |> List.rev
  |> List.find_map (fun (message : Oas.Types.message) ->
       if message.role = Oas.Types.System then None
       else
         Oas.Types.text_of_message message
         |> trim_to_opt
         |> Option.map (truncate_text ~max_chars:180))

let continuity_summary_of_messages (messages : Oas.Types.message list) =
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
    (checkpoint : Oas.Checkpoint.t) =
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
            Prometheus.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", "boot_resume_persist");
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s %s: read_meta failed: %s"
            name
            (if paused then "pause" else "resume")
            err;
          Prometheus.inc_counter
            Prometheus.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", "boot_resume_persist");
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
            Prometheus.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", "boot_resume_check");
                     ("reason", "meta_missing")]
            ()
      | Error err ->
          Log.Keeper.error
            "keeper %s boot: read_meta failed during auto-resume check: %s"
            name
            err;
          Prometheus.inc_counter
            Prometheus.metric_keeper_paused_state_persist_errors
            ~labels:[("phase", "boot_resume_check");
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
          (match action_str with
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
               Prometheus.metric_keeper_paused_state_persist_errors
               ~labels:[("phase", "directive");
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
               Prometheus.metric_keeper_paused_state_persist_errors
               ~labels:[("phase", "directive");
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
      let entries =
        Trajectory.read_entries_since ~masc_root ~keeper_name:name ~since
      in
      let tools = Trajectory.aggregate_tool_stats entries in
      let timeline = Trajectory.hourly_timeline entries in
      let json = `Assoc [
        ("keeper", `String name);
        ("window_hours", `Int window_hours);
        ("total_entries", `Int (List.length entries));
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
      let json = `Assoc [
        ("keeper", `String name);
        ("count", `Int (List.length entries));
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
      let tool_policy_mode : [`Preset of string | `Custom] option =
        match meta with
        | Ok (Some m) ->
          (match Keeper_types.tool_access_custom_allowlist m.tool_access with
           | Some _ -> Some `Custom
           | None ->
             (match Keeper_types.tool_access_preset m.tool_access with
              | Some preset ->
                Some (`Preset (Keeper_types.tool_preset_to_string preset))
              | None -> None))
        | _ -> None
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
          ?tool_policy_mode
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
              ~base_cascade:m.cascade_name ~phase:current
          in
          let models = Cascade_runtime.models_of_cascade_name
            routing.effective_cascade
          in
          let last_model = m.runtime.usage.last_model_used in
          let last_provider_result =
            if last_model <> "" then Some last_model else None
          in
          (* Provider health derivation: mark the model that served the
             most recent successful call [`Healthy], everything else
             [`Unknown]. Full per-provider health tracking is tracked as
             a follow-up — this surfaces what the runtime already knows. *)
          let provider_health =
            List.map (fun model ->
              let h : Keeper_decision_audit.provider_health =
                match last_provider_result with
                | Some p when p = model -> `Healthy
                | _ -> `Unknown
              in
              (model, h))
              models
          in
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
            ~models ~last_provider_result ()
        | _ ->
          Keeper_decision_audit.cascade_fsm_to_mermaid
            ~models:["(unknown)"] ~last_provider_result:None ()
      in
      let cascade_models =
        match meta with
        | Ok (Some m) ->
          Cascade_runtime.models_of_cascade_name
            m.cascade_name
        | _ -> ["(unknown)"]
      in
      let last_provider =
        match meta with
        | Ok (Some m) when m.runtime.usage.last_model_used <> "" ->
          `String m.runtime.usage.last_model_used
        | _ -> `Null
      in
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
    let base_path = state.Mcp_server.room_config.base_path in
    let snapshots =
      Keeper_composite_observer.all_snapshots ~base_path ()
    in
    let json =
      `Assoc [
        "generated_at", `Float (Unix.gettimeofday ());
        "count", `Int (List.length snapshots);
        "snapshots",
          `List
            (List.map
               Keeper_composite_observer.snapshot_to_json snapshots);
      ]
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
         let snapshot =
           Keeper_composite_observer.observe entry
         in
         let json = Keeper_composite_observer.snapshot_to_json snapshot in
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
