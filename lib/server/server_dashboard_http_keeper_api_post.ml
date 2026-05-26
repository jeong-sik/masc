(** Keeper HTTP API POST handlers — tool policy, config update, lifecycle. *)

module Http = Http_server_eio
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Trace = Server_dashboard_http_keeper_api_trace

include Server_dashboard_http_keeper_api_types

let dedupe_tool_names names =
  Json_util.dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

let json_list_length = function
  | `List l -> List.length l
  | _ -> 0
;;

let trajectory_line_ts = Trace.line_ts
let dedupe_thinking_lines = Trace.dedupe_thinking_lines

let read_internal_history_lines = Trace.read_internal_history_lines
let merge_keeper_trace_lines = Trace.merge_keeper_trace_lines

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

(* Trajectory preview helpers moved to Server_dashboard_http_keeper_api_types. *)

let stat_json_of_path = Checkpoints.stat_json_of_path
let oas_checkpoint_summary_json = Checkpoints.oas_checkpoint_summary_json
let keeper_checkpoint_inventory_json = Checkpoints.inventory_json

let linked_artifact_json = Checkpoints.linked_artifact_json

include Server_dashboard_http_keeper_runtime_manifest_scan

(* Runtime-manifest receipt + scan-summary helpers in Server_dashboard_http_keeper_api_scan_summary. *)
module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let receipt_row_matches = Scan_summary.receipt_row_matches
let read_receipt_rows = Scan_summary.read_receipt_rows
let unique_ints = Scan_summary.unique_ints
let json_int_list = Scan_summary.json_int_list
let json_int_opt = Scan_summary.json_int_opt
let event_bus_summary_json = Scan_summary.event_bus_summary_json
let memory_summary_json = Scan_summary.memory_summary_json

let max_int_list_opt = Scan_summary.max_int_list_opt
let selected_keeper_turn_id = Scan_summary.selected_keeper_turn_id
let terminal_event_present_for_turn = Scan_summary.terminal_event_present_for_turn

let runtime_lens_json =
  Server_dashboard_http_keeper_api_runtime_lens.runtime_lens_json

let provider_attempts_summary_json =
  Server_dashboard_http_keeper_api_summary_aggregates.provider_attempts_summary_json
;;

let turn_identity_summary_json =
  Server_dashboard_http_keeper_api_summary_aggregates.turn_identity_summary_json
;;

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
                runtime_lens_json ~config ~keeper_name:name ~trace_id ?turn_id
                  manifest_scan );
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

let refresh_keeper_execution_surfaces =
  Server_dashboard_http_keeper_api_lifecycle_post.refresh_keeper_execution_surfaces

let invalidate_keeper_execution_surfaces =
  Server_dashboard_http_keeper_api_lifecycle_post.invalidate_keeper_execution_surfaces
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

let handle_keeper_lifecycle_post =
  Server_dashboard_http_keeper_api_lifecycle_post.handle_keeper_lifecycle_post
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
        | Some "pause" -> Ok `Pause
        | Some "resume" -> Ok `Resume
        | Some "wakeup" -> Ok `Wakeup
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
    | Ok directive ->
        let config = state.Mcp_server.room_config in
        let action_str =
          match directive with
          | `Pause -> "pause"
          | `Resume -> "resume"
          | `Wakeup -> "wakeup"
        in
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
          (match directive with
           | `Pause -> persist_paused_state true
           | `Resume -> persist_paused_state false
           | `Wakeup -> ());
          let resolved_agent_name =
            match Keeper_registry_lookup.find_by_name name with
            | Some entry -> entry.meta.agent_name
            | None -> (
                match meta_opt with
                | Some meta -> meta.agent_name
                | None -> Keeper_identity.keeper_agent_name name)
          in
          Keeper_keepalive.process_directive
            ~agent_name:resolved_agent_name action_str;
          (match directive with
           | `Pause -> refresh_keeper_execution_surfaces ~config ~name "paused"
           | `Resume -> refresh_keeper_execution_surfaces ~config ~name "resumed"
           | `Wakeup -> invalidate_keeper_execution_surfaces ~config ());
          Http.Response.json ~compress:true ~request:req
            (Printf.sprintf {|{"ok":true,"action":"%s","name":"%s"}|}
               (String.escaped action_str) (String.escaped name))
            reqd
        in
        let needs_meta_for_state_transition =
          match directive with
          | `Pause | `Resume -> true
          | `Wakeup -> false
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
               ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Directive));
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
               ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Directive));
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

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory. *)

