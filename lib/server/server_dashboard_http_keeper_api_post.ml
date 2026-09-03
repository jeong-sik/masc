(** Keeper HTTP API POST handlers — config update and lifecycle. *)

module Http = Http_server_eio
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Trace = Server_dashboard_http_keeper_api_trace

include Server_dashboard_http_keeper_api_types

let json_list_length = function
  | `List l -> List.length l
  | _ -> 0
;;

let respond_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http.Response.json_value ?request ~status (error_json ?ok message) reqd

let github_login_stream_headers origin =
  Httpun.Headers.of_list
    ([ "content-type", "text/event-stream"
     ; "cache-control", "no-cache"
     ; "connection", "close"
     ; "x-accel-buffering", "no"
     ]
     @ Server_auth.cors_headers origin)
;;

let github_login_stream_send_with ~write ~flush event json =
  write (Printf.sprintf "event: %s\ndata: %s\n\n" event (Yojson.Safe.to_string json));
  flush ()
;;

let github_login_stream_send writer =
  github_login_stream_send_with
    ~write:(Httpun.Body.Writer.write_string writer)
    ~flush:(fun () -> Httpun.Body.Writer.flush writer (fun _ -> ()))
;;

let handle_keeper_github_login_post state req reqd =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_suffix req_path keeper_suffix_github_login in
  let config = Mcp_server.workspace_config state in
  if name = "" then respond_error reqd "keeper name is required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    (* Effective meta, not persisted meta: [sandbox_profile] is TOML-owned and
       a persisted read answers with the default, which would send every
       Keeper's login to this host. *)
    match Keeper_meta_store.read_effective_meta config name with
    | Error message -> respond_error ~status:`Internal_server_error reqd message
    | Ok None ->
      respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    | Ok (Some meta) ->
      let hostname =
        match Server_utils.query_param req "hostname" with
        | Some hostname -> hostname
        | None -> "github.com"
      in
      let headers = github_login_stream_headers (Server_auth.get_origin req) in
      let response = Httpun.Response.create ~headers `OK in
      let writer = Httpun.Reqd.respond_with_streaming reqd response in
      Fun.protect
        ~finally:(fun () -> Httpun.Body.Writer.close writer)
        (fun () ->
           match
             Keeper_github_identity.stream_login
               ~config
               ~keeper_name:name
               (* Shaping a Remote_ssh lane runs commands on the endpoint. Doing
                  that before this response existed left the browser waiting on
                  a request that had not answered at all. *)
               ~make_lane:(fun () ->
                 Keeper_github_login_lane.for_keeper ~config ~meta ~hostname)
               ~is_closed:(fun () -> Httpun.Body.Writer.is_closed writer)
               ~send_event:(github_login_stream_send writer)
           with
           | Ok () -> ()
           | Error message when not (Httpun.Body.Writer.is_closed writer) ->
             github_login_stream_send
               writer
               "error"
               (`Assoc [ "message", `String message ])
           | Error _ -> ())
;;

let declared_provider_id json =
  match Json_util.assoc_member_opt "provider" json with
  | Some (`String value) when String.trim value <> "" -> Ok (String.trim value)
  | Some _ -> Error "provider must be a non-empty string"
  | None -> Error "provider required"
;;

(* Attaching one Keeper to one declared work service. Answers with the URL
   the operator has to open; the provider sends the browser to
   [Server_keeper_oauth_http]'s callback, which is where credentials are
   actually written. Nothing is written to the Keeper by this request. *)
let handle_keeper_oauth_login_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_suffix req_path keeper_suffix_oauth_login in
  let config = Mcp_server.workspace_config state in
  if name = "" then respond_error reqd "keeper name is required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    match Keeper_meta_store.read_meta config name with
    | Error message -> respond_error ~status:`Internal_server_error reqd message
    | Ok None ->
      respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    | Ok (Some _) ->
      (match Yojson.Safe.from_string body_str with
       | exception Yojson.Json_error detail -> respond_error reqd detail
       | args ->
         (match declared_provider_id args with
          | Error message -> respond_error reqd message
          | Ok provider_id ->
            (match
               Server_keeper_oauth.start
                 ~base_path:config.Workspace.base_path
                 ~keeper:name
                 ~provider_id
                 ~now:(Unix.gettimeofday ())
             with
             | Error message -> respond_error reqd message
             | Ok payload ->
               Http.Response.json_value ~compress:true ~request:req payload reqd)))
;;

(* Ask an attached service again what tools it has. The same work the
   callback does when a Keeper attaches, reachable on its own so a catalog
   that went stale does not need a whole new consent. *)
let handle_keeper_identity_refresh_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name =
    extract_keeper_name_for_suffix req_path keeper_suffix_identity_refresh
  in
  let config = Mcp_server.workspace_config state in
  if name = "" then respond_error reqd "keeper name is required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    match Keeper_meta_store.read_meta config name with
    | Error message -> respond_error ~status:`Internal_server_error reqd message
    | Ok None ->
      respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    | Ok (Some _) ->
      (match Yojson.Safe.from_string body_str with
       | exception Yojson.Json_error detail -> respond_error reqd detail
       | args ->
         (match declared_provider_id args with
          | Error message -> respond_error reqd message
          | Ok provider_id ->
            (match
               Server_keeper_oauth.refresh_tools
                 ~base_path:config.Workspace.base_path
                 ~keeper:name
                 ~provider_id
                 ~now:(Unix.gettimeofday ())
             with
             | Error message -> respond_error reqd message
             | Ok payload ->
               Http.Response.json_value ~compress:true ~request:req payload reqd)))
;;

(* Turn one attached service on or off for this keeper without touching the
   consent: the token and catalog stay, the keeper's turns stop being handed
   that provider's tools. The actor comes from the authenticated operator so
   the audit row says who threw the switch. *)
let handle_keeper_identity_switch_post state ~actor req reqd body_str =
  let req_path = Http.Request.path req in
  let name =
    extract_keeper_name_for_suffix req_path keeper_suffix_identity_switch
  in
  let config = Mcp_server.workspace_config state in
  if name = "" then respond_error reqd "keeper name is required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    match Keeper_meta_store.read_meta config name with
    | Error message -> respond_error ~status:`Internal_server_error reqd message
    | Ok None ->
      respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    | Ok (Some _) ->
      (match Yojson.Safe.from_string body_str with
       | exception Yojson.Json_error detail -> respond_error reqd detail
       | args ->
         (match declared_provider_id args with
          | Error message -> respond_error reqd message
          | Ok provider_id ->
            let enabled =
              match args with
              | `Assoc fields ->
                (match List.assoc_opt "enabled" fields with
                 | Some (`Bool value) -> Ok value
                 | Some _ -> Error "enabled must be a boolean"
                 | None -> Error "enabled is required")
              | _ -> Error "body must be a JSON object"
            in
            (match enabled with
             | Error message -> respond_error reqd message
             | Ok enabled ->
               (match
                  Keeper_identity_switch.set
                    config
                    ~actor
                    ~keeper_name:name
                    ~provider_id
                    ~enabled
                with
                | Error message ->
                  respond_error ~status:`Internal_server_error reqd message
                | Ok () ->
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (`Assoc
                       [ "ok", `Bool true
                       ; "keeper", `String name
                       ; "provider", `String provider_id
                       ; "enabled", `Bool enabled
                       ])
                    reqd))))
;;

let parse_fusion_result text =
  try Yojson.Safe.from_string text with
  | Yojson.Json_error _ -> `Assoc [ "ok", `Bool false; "error", `String text ]
;;

(* Operator-initiated deliberation: runs [Fusion_tool.handle] from an HTTP
   request with the prompt, preset and topology the operator supplied. The
   judge-of-judges and staged topologies the tool advertises had no reachable
   HTTP surface before this: only a keeper deciding on its own to call the tool
   could exercise them. The run is owned by [name], so its wake, board post and
   chat delivery land on that keeper exactly as a self-initiated run would.

   Validation stays in the tool. Preset/topology/prompt rejections come back as
   the tool's own typed refusals rather than a second copy of those rules here,
   which is what keeps this endpoint from drifting away from what a keeper-side
   call would do. *)
let handle_keeper_fusion_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_suffix req_path keeper_suffix_fusion in
  if name = "" then respond_error reqd "keeper name required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    try
      let args = Yojson.Safe.from_string body_str in
      let prompt =
        match Json_util.assoc_member_opt "prompt" args with
        | Some (`String value) -> String.trim value
        | _ -> ""
      in
      if prompt = "" then respond_error reqd "prompt is required"
      else
        let config = Mcp_server.workspace_config state in
        let now_unix = Time_compat.now () in
        match Eio_context.get_root_switch_opt (), Eio_context.get_net_opt () with
        | None, _ | _, None ->
          respond_error reqd "fusion requires the server root switch + net (unavailable)"
        | Some sw, Some net ->
          (match Fusion_config_loader.load ~base_path:config.base_path with
           | Error msg -> respond_error reqd msg
           | Ok policy ->
             let string_arg key =
               match Json_util.assoc_member_opt key args with
               | Some (`String value) when String.trim value <> "" ->
                 [ key, `String (String.trim value) ]
               | _ -> []
             in
             let web_tools =
               match Json_util.assoc_member_opt "web_tools" args with
               | Some (`Bool value) -> [ "web_tools", `Bool value ]
               | _ -> []
             in
             (* preset/topology 를 생략하면 도구의 기본값(default_preset / simple)이
                그대로 적용된다 — 여기서 기본값을 새로 정하지 않는다. *)
             let fusion_args =
               `Assoc
                 (("prompt", `String prompt)
                  :: (string_arg "preset" @ string_arg "topology" @ web_tools))
             in
             let raw =
               Fusion_tool.handle ~sw ~net ~base_dir:config.base_path ~keeper:name
                 ~now_unix ~policy ~args:fusion_args ()
             in
             let fusion_json = parse_fusion_result raw in
             (match Json_util.assoc_member_opt "ok" fusion_json with
              | Some (`Bool true) ->
                (match Json_util.assoc_member_opt "run_id" fusion_json with
                 | Some (`String run_id) ->
                   Http.Response.json_value ~compress:true ~request:req
                     (`Assoc
                        [ "ok", `Bool true
                        ; "status", `String "fusion_started"
                        ; "run_id", `String run_id
                        ; "owner_keeper", `String name
                        ; "fusion_route", `String ("/#fusion?run_id=" ^ run_id)
                        ])
                     reqd
                 | _ -> respond_error reqd "fusion accepted without canonical run_id")
              | _ ->
                let message =
                  match Json_util.assoc_member_opt "error" fusion_json with
                  | Some (`String msg) -> msg
                  | _ ->
                    (match Json_util.assoc_member_opt "reason" fusion_json with
                     | Some (`String msg) -> msg
                     | _ -> "fusion refused the request")
                in
                respond_error reqd message))
    with
    | Yojson.Json_error msg -> respond_error reqd ("invalid JSON body: " ^ msg)
;;

(* Trajectory preview helpers moved to Server_dashboard_http_keeper_api_types. *)

let stat_json_of_path = Checkpoints.stat_json_of_path
let agent_core_checkpoint_summary_json = Checkpoints.agent_core_checkpoint_summary_json
let keeper_checkpoint_inventory_json = Checkpoints.inventory_json

let linked_artifact_json = Checkpoints.linked_artifact_json

include Server_dashboard_http_keeper_runtime_manifest_scan

(* Runtime-manifest receipt + scan-summary helpers in Server_dashboard_http_keeper_api_scan_summary. *)
module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let read_receipt_rows = Scan_summary.read_receipt_rows
let event_bus_summary_json = Scan_summary.event_bus_summary_json

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

let keeper_runtime_trace_json (config : Workspace.config) (name : string)
    ?trace_id ?turn_id ?(limit = 200) ()
    : [ `OK | `Not_found ] * Yojson.Safe.t =
  if not (Keeper_config.validate_name name) then
    ( `Not_found,
      `Assoc
        [ ("error", `String (Printf.sprintf "invalid keeper name: %s" name)) ] )
  else
    let trace_id_query =
      match trace_id with
      | Some value -> String_util.trim_nonempty value
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
          match Keeper_meta_store.read_meta_resolved config name with
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
          |> List_util.take_last limit
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
              ( "turn_id", Json_util.int_opt_to_json turn_id );
              ("manifest_path", `String manifest_scan.path);
              ("manifest_path_present", `Bool (Fs_compat.file_exists manifest_scan.path));
              ("manifest_total_rows", `Int manifest_scan.total_rows);
              ( "manifest_total_rows_exact",
                `Bool (manifest_scan.scanned_lines < manifest_scan.scan_line_limit) );
              ( "manifest_scan_diagnostics"
              , runtime_manifest_scan_diagnostics_json manifest_scan );
              ("manifest_returned_rows", `Int (List.length manifest_rows));
              ("receipt_returned_rows", `Int (List.length receipts));
              ( "turn_identity",
                turn_identity_summary_json ?turn_id manifest_scan receipts );
              ("provider_attempts", provider_attempts_summary_json manifest_scan);
              ("event_bus", event_bus_summary_json manifest_scan);
              ( "runtime_lens",
                runtime_lens_json ~config ~keeper_name:name ~trace_id ?turn_id
                  manifest_scan );
              ("health", `String health);
              ( "stale_reason", Json_util.string_opt_to_json stale_reason );
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
                           (linked_artifact_json ~kind:"agent_core_checkpoint")
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
    respond_error ~ok:false reqd "keeper name is required"
  else
    let config = (Mcp_server.workspace_config state) in
    try
      let args = Yojson.Safe.from_string body_str in
      let action = Safe_ops.json_string ~default:"" "action" args in
      match action with
      | ("preview_purge" | "apply_purge") as purge_action ->
          let apply = String.equal purge_action "apply_purge" in
          (match Checkpoints.purge_current config ~keeper_name:name ~apply with
           | Error error ->
             let status =
               match error with
               | Checkpoints.Purge_invalid_keeper_name _ -> `Bad_request
               | Checkpoints.Purge_keeper_not_found _ -> `Not_found
               | Purge_keeper_active _
               | Purge_checkpoint_invalid _
               | Purge_source_changed -> `Conflict
               | Purge_checkpoint_unavailable _
               | Purge_backup_failed _
               | Purge_install_failed _ -> `Internal_server_error
             in
             respond_error
               ~status
               ~request:req
               ~ok:false
               reqd
               (Checkpoints.purge_error_to_string error)
           | Ok result ->
             let (_status, inventory) =
               keeper_checkpoint_inventory_json config name
             in
             let response =
               match Checkpoints.purge_result_json ~action:purge_action result with
               | `Assoc fields -> `Assoc (("inventory", inventory) :: fields)
               | other -> other
             in
             Http.Response.json_value ~compress:true ~request:req response reqd)
      | "delete_history" ->
          let snapshot_ids =
            Safe_ops.json_string_list "snapshot_ids" args
            |> List.map String.trim
            |> List.filter (fun value -> value <> "")
            |> Json_util.dedupe_keep_order
          in
          if snapshot_ids = [] then
            respond_error ~ok:false reqd "snapshot_ids is required"
          else
            let trace_id_result =
              match Keeper_meta_store.read_meta_resolved config name with
              | Ok (Some (_, meta)) ->
                  Ok (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
              | Ok None ->
                  Error (Printf.sprintf "keeper %S not found" name)
              | Error msg -> Error msg
            in
            (match trace_id_result with
             | Error msg ->
                 respond_error ~status:`Not_found ~ok:false reqd msg
             | Ok trace_id ->
                 let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
                 let (deleted, missing) =
                   Keeper_checkpoint_store.delete_agent_core_history_files
                     ~session_dir ~snapshot_ids
                 in
                 let (_status, inventory) =
                   keeper_checkpoint_inventory_json config name
                 in
                 Http.Response.json_value ~compress:true ~request:req
                   (`Assoc
                      [
                        ("ok", `Bool true);
                        ("action", `String "delete_history");
                        ("keeper", `String name);
                        ("deleted_snapshot_ids", `List (List.map (fun id -> `String id) deleted));
                        ("missing_snapshot_ids", `List (List.map (fun id -> `String id) missing));
                        ("inventory", inventory);
                   ])
                   reqd)
      | "" ->
          respond_error ~ok:false reqd "action is required"
      | other ->
          respond_error ~ok:false reqd (Printf.sprintf "unknown action: %s" other)
    with
    | Yojson.Json_error e ->
        respond_error ~ok:false reqd (Printf.sprintf "invalid json: %s" e)

let refresh_keeper_execution_surfaces =
  Server_dashboard_http_keeper_api_lifecycle_post.refresh_keeper_execution_surfaces

let invalidate_keeper_execution_surfaces =
  Server_dashboard_http_keeper_api_lifecycle_post.invalidate_keeper_execution_surfaces

let dashboard_config_string_fields =
  [
    "runtime_id";
    "instructions";
    "sandbox_profile";
    "network_mode";
  ]

let dashboard_config_bool_fields =
  [
    "autoboot_enabled";
    "proactive_enabled";
  ]

let dashboard_config_string_list_fields =
  [
    "mention_targets";
  ]

(* Accepts a string or an explicit null, so it cannot join
   [dashboard_config_string_fields] -- that list's check demands a string and
   would refuse the clear. Null is how an operator detaches the endpoint when
   moving off remote_ssh; omitting the field instead carries the keeper TOML's
   value forward into a profile that refuses it
   ([remote_endpoint_requires_remote_ssh]). *)
let remote_endpoint_field = "remote_endpoint"

(* Control field (not persisted): explicit acknowledgement that reducing
   [max_context_override] may make the existing conversation exceed the next
   request budget. Stripped before the config is parsed/applied. *)
let confirm_context_shrink_field = "confirm_context_shrink"
let expected_config_revision_field = "expected_config_revision"

let dashboard_config_patch_allowed_fields =
  [ "name"
  ; "tools"
  ; "skills"
  ; "max_context_override"
  ; confirm_context_shrink_field
  ; expected_config_revision_field
  ; remote_endpoint_field
  ]
  @
  dashboard_config_string_fields
  @ dashboard_config_bool_fields
  @ dashboard_config_string_list_fields

let dedupe_keep_order_strings values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value seen then loop seen acc rest
        else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let duplicate_assoc_keys fields =
  let rec loop seen dup = function
    | [] -> dedupe_keep_order_strings (List.rev dup)
    | (key, _) :: rest ->
        if List.mem key seen then loop seen (key :: dup) rest
        else loop (key :: seen) dup rest
  in
  loop [] [] fields

let keeper_board_attention_quarantine_error_status = function
  | Keeper_board_attention_quarantine_command.Candidate_state_conflict _
  | Keeper_board_attention_quarantine_command.Partition_state_conflict _ ->
    `Conflict
  | Keeper_board_attention_quarantine_command.Durability_unconfirmed _
  | Keeper_board_attention_quarantine_command.Wake_request_failed _ ->
    `Service_unavailable
;;

let handle_keeper_board_attention_quarantine_recovery_post
      state
      agent_name
      req
      reqd
      ~keeper_name
      ~raw_partition_id
      body_str
  =
  let module Command = Keeper_board_attention_quarantine_command in
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request:req json reqd
  in
  let parsed =
    try Yojson.Safe.from_string body_str |> Command.parse_request with
    | Yojson.Json_error _ -> Error (Command.Invalid_field "request body")
  in
  match parsed with
  | Error error ->
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String Command.result_schema
        ; "ok", `Bool false
        ; "error", Command.input_error_to_json error
        ])
  | Ok recovery_request ->
    (match
       Command.make
         ~keeper_name
         ~raw_partition_id
         recovery_request
     with
     | Error error ->
       respond
         ~status:`Bad_request
         (`Assoc
           [ "schema", `String Command.result_schema
           ; "ok", `Bool false
           ; "error", Command.input_error_to_json error
           ])
     | Ok command ->
       let config = Mcp_server.workspace_config state in
       let result =
         Command.execute
           ~now:(Time_compat.now ())
           ~base_path:config.Workspace.base_path
           command
       in
       let audit =
         Command.audit
           config
           ~actor:agent_name
           command
           ~outcome:
             (match result with
              | Ok _ -> Audit_log.Success
              | Error error ->
                Audit_log.Failure (Command.execution_error_label error))
         |> Command.audit_json
       in
       (match result with
        | Ok report ->
          Operator_control.invalidate_snapshot_cache ();
          Dashboard_projection_cache.invalidate_snapshot_json ~config;
          respond (Command.success_json ~audit command report)
        | Error error ->
          respond
            ~status:(keeper_board_attention_quarantine_error_status error)
            (Command.failure_json ~audit error)))
;;

let dashboard_field_type_error key expected value =
  Error
    (Printf.sprintf "%s must be %s (received %s)" key expected
       (Json_util.kind_name value))

let validate_dashboard_string_list_field key = function
  | `List items ->
      let rec loop index = function
        | [] -> Ok ()
        | `String _ :: rest -> loop (index + 1) rest
        | bad :: _ ->
            Error
              (Printf.sprintf "%s[%d] must be a string (received %s)" key index
                 (Json_util.kind_name bad))
      in
      loop 0 items
  | other -> dashboard_field_type_error key "an array of strings" other

let validate_dashboard_max_context_override = function
  | `Null -> Ok ()
  | `Int value ->
      Keeper_config.validate_max_context_override_value value |> Result.map ignore
  | other -> dashboard_field_type_error "max_context_override" "an integer or null" other

let validate_dashboard_config_field key value =
  if key = "name" then
    match value with
    | `String _ -> Ok ()
    | other -> dashboard_field_type_error key "a string" other
  else if key = "tools" then
    (match value with
     | `Assoc _ -> Ok ()
     | other -> dashboard_field_type_error key "an object" other)
  else if key = "skills" then
    (match value with
     | `Assoc _ -> Ok ()
     | other -> dashboard_field_type_error key "an object" other)
  else if key = "max_context_override" then
    validate_dashboard_max_context_override value
  else if key = confirm_context_shrink_field then
    (match value with
     | `Bool _ -> Ok ()
     | other -> dashboard_field_type_error key "a boolean" other)
  else if key = expected_config_revision_field then
    Keeper_turn_up_config_persistence.config_revision_of_yojson value
    |> Result.map ignore
  else if key = remote_endpoint_field then
    (* Shape only. Whether the name is declared under [exec.ssh.endpoints], and
       whether the profile admits an endpoint at all, are decided by
       [Keeper_turn_up_args.parse] on the apply path. *)
    (match value with
     | `String raw ->
         if String.trim raw = "" then
           Error "remote_endpoint must not be blank (send null to clear it)"
         else Ok ()
     | `Null -> Ok ()
     | other -> dashboard_field_type_error key "a string or null" other)
  else if List.mem key dashboard_config_string_fields then
    match value with
    | `String _ -> Ok ()
    | other -> dashboard_field_type_error key "a string" other
  else if List.mem key dashboard_config_bool_fields then
    match value with
    | `Bool _ -> Ok ()
    | other -> dashboard_field_type_error key "a boolean" other
  else if List.mem key dashboard_config_string_list_fields then
    validate_dashboard_string_list_field key value
  else Ok ()

let validate_dashboard_config_patch ~meta:_ fields =
  match duplicate_assoc_keys fields with
  | _ :: _ as duplicates ->
      Error
        (Printf.sprintf "duplicate dashboard config field(s): %s"
           (String.concat ", " duplicates))
  | [] ->
      let unknown =
        fields
        |> List.filter_map (fun (key, _) ->
             if List.mem key dashboard_config_patch_allowed_fields then None
             else Some key)
        |> dedupe_keep_order_strings
      in
      if unknown <> [] then
        Error
          (Printf.sprintf "unsupported dashboard config field(s): %s"
             (String.concat ", " unknown))
      else
        let rec validate_types = function
          | [] -> Ok ()
          | (key, value) :: rest ->
              (match validate_dashboard_config_field key value with
               | Error msg -> Error msg
               | Ok () -> validate_types rest)
        in
        (match validate_types fields with
         | Error msg -> Error msg
         | Ok () -> Ok ())

(* [Some (previous_display, new_value)] when the patch reduces the keeper's
   context window below its current setting — introducing a cap where there was
   none (full model window -> capped), or lowering an existing cap. [None] when
   the field is absent, set to Null (removing the cap = expand), or raised.
   Compares the persisted override only; a stricter check against the live
   checkpoint token size is a follow-up. *)
let context_shrink_of_patch ~(meta : Keeper_meta_contract.keeper_meta) fields =
  match List.assoc_opt "max_context_override" fields with
  | Some (`Int new_v) ->
    (match meta.Keeper_meta_contract.max_context_override with
     | None -> Some ("unset (full model window)", new_v)
     | Some old_v when new_v < old_v -> Some (string_of_int old_v, new_v)
     | Some _ -> None)
  | _ -> None

let invalidate_config_surfaces ~(config : Workspace.config) ~name runtime_event =
  Dashboard_cache.invalidate (keeper_config_cache_key config name);
  Dashboard_cache.invalidate (keeper_composite_cache_key config name);
  Dashboard_cache.invalidate_prefix
    (Printf.sprintf "dashboard:fleet-composite:%s" config.base_path);
  match runtime_event with
  | Some event -> refresh_keeper_execution_surfaces ~config ~name event
  | None -> invalidate_keeper_execution_surfaces ~config ()

let respond_config_sync_error
      ?config_write
      ~request
      reqd
      ~status
      ~name
      ~config_applied
      ~code
      ~detail
      ()
  =
  Http.Response.json_value
    ~status
    ~request
    (`Assoc
      ([ "ok", `Bool false
       ; "keeper", `String name
       ; "config_applied", `Bool config_applied
       ; "runtime_sync", `Bool false
       ; "error", `Assoc [ "code", `String code; "detail", `String detail ]
       ]
       @
       match config_write with
       | Some receipt -> [ "config_write", receipt ]
       | None -> []))
    reqd

let config_write_receipt result =
  match Tool_result.metadata result with
  | Some (`Assoc fields) -> List.assoc_opt "keeper_config_write" fields
  | Some _ | None -> None

let respond_config_reconciliation ~request reqd ~name ~error =
  Http.Response.json_value
    ~status:`Service_unavailable
    ~request
    (`Assoc
       [ "ok", `Bool false
       ; "keeper", `String name
       ; "config_application", `Assoc [ "state", `String "indeterminate" ]
       ; "runtime_sync", `Bool false
       ; "error", error
       ; "authoritative_reload_required", `Bool true
       ])
    reqd

let respond_config_revision_conflict ~request reqd ~name
      ({ expected; observed } : Keeper_turn_up_config_persistence.conflict)
  =
  Http.Response.json_value
    ~status:`Conflict
    ~request
    (`Assoc
      [ "ok", `Bool false
      ; "keeper", `String name
      ; "config_applied", `Bool false
      ; "runtime_sync", `Bool false
      ; ( "error"
        , `Assoc
            [ "code", `String Keeper_turn_up_update.config_revision_conflict_code
            ; "expected", Keeper_turn_up_config_persistence.config_revision_to_yojson expected
            ; "observed", Keeper_turn_up_config_persistence.config_revision_to_yojson observed
            ] )
      ])
    reqd

let handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_config in
  if String.length name = 0 then
    respond_error reqd "keeper name is required"
  else
    let workspace_scope = Mcp_server.workspace_scope state in
    let config = workspace_scope.config in
    match Keeper_meta_store.read_meta config name with
    | Error msg -> respond_error ~status:`Not_found reqd msg
    | Ok None ->
        respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
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
               let expected_config_revision =
                 match List.assoc_opt expected_config_revision_field fields with
                 | None -> Error "expected_config_revision is required"
                 | Some value ->
                   Keeper_turn_up_config_persistence.config_revision_of_yojson value
               in
               (match expected_config_revision with
                | Error detail -> respond_error reqd detail
                | Ok expected_config_revision ->
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
                 respond_error reqd
                   (Printf.sprintf "keeper name mismatch: route=%S body=%S" name
                      (Option.value ~default:"" body_name))
               else
                 (match validate_dashboard_config_patch ~meta:meta0 fields with
                  | Error msg -> respond_error reqd msg
                  | Ok () ->
                      let confirm_context_shrink =
                        match
                          List.assoc_opt confirm_context_shrink_field fields
                        with
                        | Some (`Bool b) -> b
                        | _ -> false
                      in
                      (* Control field: consumed here, never persisted. *)
                      let fields =
                        List.remove_assoc confirm_context_shrink_field fields
                        |> List.remove_assoc expected_config_revision_field
                      in
                      (match context_shrink_of_patch ~meta:meta0 fields with
                       | Some (previous, new_v) when not confirm_context_shrink ->
                           respond_error reqd
                             (Printf.sprintf
                                "reducing max_context_override (%s -> %d) can push \
                                 this keeper's existing context past the new window \
                                 and make its next request exceed the window. Re-send \
                                 with %S: true to apply."
                                previous new_v confirm_context_shrink_field)
                       | _ ->
                      let args_with_name =
                        `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
                      in
                      let keeper_ctx : _ Keeper_tool_surface.context =
                        {
                          config;
                          agent_name;
                          sw;
                          clock;
                          proc_mgr = state.Mcp_server.proc_mgr;
                          net = state.Mcp_server.net;
                          publication_recovery_provider =
                            Mcp_server.publication_recovery_availability_provider state;
                        }
                      in
                      (match
                         Keeper_turn_up_args.parse keeper_ctx args_with_name
                       with
                       | Error result ->
                           respond_error reqd
                             (Keeper_types_profile.tool_result_body result)
                       | Ok parsed ->
                           (
                           (* Dashboard edits commit a closed Owner profile
                              command, so they cannot overwrite runtime counters.
                              [preserve_prompt_defaults] keeps existing prompt
                              fields when the request omits them. *)
                           let result =
                             Keeper_turn_up_update.update_keeper
                               ~preserve_prompt_defaults:true
                               ~expected_config_revision
                               keeper_ctx parsed
                               meta0
                           in
                           (match
                              Keeper_turn_up_update
                              .config_revision_conflict_of_result result
                            with
                            | Some conflict ->
                              respond_config_revision_conflict
                                ~request:req reqd ~name conflict
                            | None ->
                           (match
                              Keeper_turn_up_update
                              .config_reconciliation_required_of_result result
                            with
                            | Some error ->
                              respond_config_reconciliation
                                ~request:req
                                reqd
                                ~name
                                ~error
                            | None ->
                           (match
                              Keeper_turn_up_update
                              .config_publication_rollback_of_result result
                            with
                            | Some detail ->
                              respond_config_sync_error
                                ?config_write:(config_write_receipt result)
                                ~request:req
                                reqd
                                ~status:`Service_unavailable
                                ~name
                                ~config_applied:false
                                ~code:"keeper_config_publication_rolled_back"
                                ~detail
                                ()
                            | None ->
                           if not
                                (Keeper_types_profile.tool_result_success result)
                           then (
                             let detail = Keeper_types_profile.tool_result_body result in
                             Log.Keeper.error
                               "dashboard keeper config runtime sync failed keeper=%s: %s"
                               name
                               detail;
                             invalidate_config_surfaces ~config ~name None;
                             respond_config_sync_error
                               ?config_write:(config_write_receipt result)
                               ~request:req
                               reqd
                               ~status:`Service_unavailable
                               ~name
                               ~config_applied:true
                               ~code:"keeper_runtime_sync_failed"
                               ~detail
                               ())
                           else (
                             invalidate_config_surfaces
                               ~config
                               ~name
                               (Some
                                  (Keeper_lifecycle_events.Custom_event
                                     { verb = Keeper_lifecycle_events.Restarted
                                     ; phase =
                                         Some Keeper_state_machine.Running
                                     }));
                             let (_st, json) =
                               Dashboard_http_keeper.keeper_config_json config
                                 name
                             in
                             let json =
                               match config_write_receipt result, json with
                               | Some receipt, `Assoc fields ->
                                 `Assoc (("config_write", receipt) :: fields)
                               | Some _, _ | None, _ -> json
                             in
                             Http.Response.json_value ~compress:true
                               ~request:req json reqd)))))))))
           | None ->
               respond_error reqd "request body must be a JSON object"
         with Yojson.Json_error e ->
           respond_error reqd (Printf.sprintf "invalid json: %s" e))

let secret_projection_response_json config name =
  `Assoc
    [ "ok", `Bool true
    ; ( "secret_projection"
      , Keeper_secret_projection.dashboard_status_json
          ~base_path:config.Workspace.base_path
          ~keeper_name:name )
    ]
;;

let invalidate_keeper_secret_projection_caches config name =
  Dashboard_cache.invalidate (keeper_composite_cache_key config name);
  Dashboard_cache.invalidate_prefix
    (Printf.sprintf "dashboard:fleet-composite:%s" config.Workspace.base_path)
;;

let required_secret_string_field json name =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) -> Ok value
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " required")
;;

let required_secret_trimmed_string_field json name =
  match required_secret_string_field json name with
  | Error _ as err -> err
  | Ok value ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then Error (name ^ " must not be empty") else Ok trimmed
;;

let secret_scope_field json =
  match required_secret_trimmed_string_field json "scope" with
  | Error _ as err -> err
  | Ok value ->
    (match Keeper_secret_projection.secret_scope_of_string value with
     | Some scope -> Ok scope
     | None -> Error "scope must be shared or keeper")
;;

let handle_keeper_secrets_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_secrets in
  if String.length name = 0
  then respond_error reqd "keeper name is required"
  else
    let config = Mcp_server.workspace_config state in
    match Keeper_meta_store.read_meta config name with
    | Error msg -> respond_error ~status:`Not_found reqd msg
    | Ok None ->
      respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
    | Ok (Some _) ->
      (try
         let args = Yojson.Safe.from_string body_str in
         match args with
         | `Assoc _ ->
           let action_result = required_secret_trimmed_string_field args "action" in
           let result =
             match action_result with
             | Error _ as err -> err
             | Ok "set_env" ->
               (match
                  ( secret_scope_field args
                  , required_secret_trimmed_string_field args "name"
                  , required_secret_string_field args "value" )
                with
                | Ok scope, Ok env_name, Ok value ->
                  Keeper_secret_projection.set_env_entry
                    ~base_path:config.Workspace.base_path
                    ~keeper_name:name
                    ~scope
                    ~name:env_name
                    ~value
                | Error msg, _, _ | _, Error msg, _ | _, _, Error msg -> Error msg)
             | Ok "delete_env" ->
               (match
                  ( secret_scope_field args
                  , required_secret_trimmed_string_field args "name" )
                with
                | Ok scope, Ok env_name ->
                  Keeper_secret_projection.delete_env_entry
                    ~base_path:config.Workspace.base_path
                    ~keeper_name:name
                    ~scope
                    ~name:env_name
                | Error msg, _ | _, Error msg -> Error msg)
             | Ok "set_file" ->
               (match
                  ( secret_scope_field args
                  , required_secret_trimmed_string_field args "path"
                  , required_secret_string_field args "value" )
                with
                | Ok scope, Ok container_path, Ok value ->
                  Keeper_secret_projection.set_file_entry
                    ~base_path:config.Workspace.base_path
                    ~keeper_name:name
                    ~scope
                    ~container_path
                    ~value
                | Error msg, _, _ | _, Error msg, _ | _, _, Error msg -> Error msg)
             | Ok "delete_file" ->
               (match
                  ( secret_scope_field args
                  , required_secret_trimmed_string_field args "path" )
                with
                | Ok scope, Ok container_path ->
                  Keeper_secret_projection.delete_file_entry
                    ~base_path:config.Workspace.base_path
                    ~keeper_name:name
                    ~scope
                    ~container_path
                | Error msg, _ | _, Error msg -> Error msg)
             | Ok action ->
               Error
                 (Printf.sprintf
                    "unsupported keeper secret action: %s"
                    action)
           in
           (match result with
            | Error msg -> respond_error reqd msg
            | Ok () ->
              invalidate_keeper_secret_projection_caches config name;
              Http.Response.json_value ~compress:true ~request:req
                (secret_projection_response_json config name)
                reqd)
         | _ -> respond_error reqd "request body must be a JSON object"
       with
       | Yojson.Json_error e ->
         respond_error reqd (Printf.sprintf "invalid json: %s" e))

let handle_keeper_lifecycle_post =
  Server_dashboard_http_keeper_api_lifecycle_post.handle_keeper_lifecycle_post

type plain_keeper_directive =
  | Plain_pause
  | Plain_wakeup

let plain_directive_action = function
  | Plain_pause -> "pause"
  | Plain_wakeup -> "wakeup"

let plain_directive_to_keeper_directive = function
  | Plain_pause -> Keeper_directive.Pause
  | Plain_wakeup -> Keeper_directive.Wakeup

type parsed_keeper_directive =
  | Plain_directive of plain_keeper_directive
  | Resume_owner of Keeper_paused_work_resume_transaction.request

type bulk_resume_target =
  { name : string
  ; request : Keeper_paused_work_resume_transaction.request
  }

type parsed_bulk_directive =
  | Bulk_plain of
      { names : string list
      ; directive : plain_keeper_directive
      }
  | Bulk_resume_owner of bulk_resume_target list

let required_resume_owner_request json =
  match Safe_ops.json_string_opt "operator_operation_id" json with
  | Some operator_operation_id ->
    Ok Keeper_paused_work_resume_transaction.{ operator_operation_id }
  | None -> Error "resume requires string \"operator_operation_id\""

let parse_keeper_directive_json json =
  (* STR-OK: HTTP boundary parse of the untrusted wire "action" field into a
     typed directive; any unknown value becomes a typed Error. *)
  match Safe_ops.json_string_opt "action" json with
  | Some "pause" -> Ok (Plain_directive Plain_pause)
  | Some "resume" ->
    Result.map
      (fun request -> Resume_owner request)
      (required_resume_owner_request json)
  | Some "wakeup" -> Ok (Plain_directive Plain_wakeup)
  | Some action ->
    Error
      (Printf.sprintf
         "invalid action %S: expected pause, resume, or wakeup"
         action)
  | None -> Error "missing \"action\" field"

let parse_bulk_resume_target = function
  | `Assoc _ as json ->
    (match Safe_ops.json_string_opt "name" json with
     | Some name when is_valid_keeper_name name ->
       Result.map
         (fun request -> { name; request })
         (required_resume_owner_request json)
     | Some _ -> Error "resume target has an invalid keeper name"
     | None -> Error "resume target requires string \"name\"")
  | _ -> Error "resume targets must be JSON objects"

let parse_bulk_resume_targets json =
  match Json_util.assoc_member_opt "targets" json with
  | Some (`List targets) when targets <> [] ->
    let rec collect seen parsed = function
      | [] -> Ok (List.rev parsed)
      | target :: rest ->
        (match parse_bulk_resume_target target with
         | Ok target when List.mem target.name seen ->
           Error (Printf.sprintf "duplicate resume target %S" target.name)
         | Ok target -> collect (target.name :: seen) (target :: parsed) rest
         | Error _ as error -> error)
    in
    collect [] [] targets
  | Some (`List []) -> Error "resume targets must be a non-empty list"
  | Some _ -> Error "resume requires array \"targets\""
  | None -> Error "resume requires array \"targets\""

let parse_bulk_plain_names json =
  match Json_util.assoc_member_opt "names" json with
  | Some (`List items) ->
    let rec collect seen parsed = function
      | [] -> Ok (List.rev parsed)
      | `String name :: rest when is_valid_keeper_name name ->
        if List.mem name seen
        then Error (Printf.sprintf "duplicate keeper name %S" name)
        else collect (name :: seen) (name :: parsed) rest
      | `String name :: _ ->
        Error (Printf.sprintf "invalid keeper name %S" name)
      | _ :: _ -> Error "names must contain only valid keeper-name strings"
    in
    (match items with
     | [] -> Error "names must be a non-empty list of valid keeper names"
     | _ -> collect [] [] items)
  | Some _ | None -> Error "names must be a non-empty list of valid keeper names"

let parse_bulk_directive_json json =
  (* STR-OK: HTTP boundary parse of the untrusted wire "action" field into a
     typed directive; any unknown value becomes a typed Error. *)
  match Safe_ops.json_string_opt "action" json with
  | Some "resume" ->
    Result.map
      (fun targets -> Bulk_resume_owner targets)
      (parse_bulk_resume_targets json)
  | Some "pause" ->
    Result.map
      (fun names -> Bulk_plain { names; directive = Plain_pause })
      (parse_bulk_plain_names json)
  | Some "wakeup" ->
    Result.map
      (fun names -> Bulk_plain { names; directive = Plain_wakeup })
      (parse_bulk_plain_names json)
  | Some action ->
    Error
      (Printf.sprintf
         "invalid action %S: expected pause, resume, or wakeup"
         action)
  | None -> Error "missing \"action\" field"

module For_testing = struct
  let github_login_stream_headers = github_login_stream_headers
  let github_login_stream_send_with = github_login_stream_send_with
  let respond_config_reconciliation = respond_config_reconciliation

  let parse_resume_request json =
    match parse_keeper_directive_json json with
    | Ok (Resume_owner request) ->
      Ok request.operator_operation_id
    | Ok (Plain_directive _) -> Error "request is not Resume_owner"
    | Error _ as error -> error
  ;;

  let parse_bulk_resume_requests json =
    match parse_bulk_directive_json json with
    | Ok (Bulk_resume_owner targets) ->
      Ok
        (List.map
           (fun target ->
              (target.name, target.request.operator_operation_id))
           targets)
    | Ok (Bulk_plain _) -> Error "request is not bulk Resume_owner"
    | Error _ as error -> error
  ;;
end

let resume_failure_message failure =
  Keeper_paused_work_resume_transaction.error_to_string
    Keeper_paused_work_resume_transaction.
      { cause = failure; reservation_release = None }

let resume_error_status (error : Keeper_paused_work_resume_transaction.error) =
  match error.cause with
  | Invalid_request _ -> `Bad_request
  | Durable_meta_missing -> `Not_found
  | Reservation_conflict _
  | Receipt_conflict _
  | Durable_owner_identity_changed
  | Durable_owner_not_paused
  | Registry_owner_identity_changed
  | Registry_owner_not_paused _ -> `Conflict
  | Receipt_lock_failed _
  | Receipt_read_failed _
  | Receipt_write_failed _
  | Durable_meta_read_failed _
  | Registry_owner_missing
  | Projection_failed _ -> `Internal_server_error

let resume_receipt_json
    (receipt : Keeper_paused_work_disposition_receipt.t) =
  `Assoc
    [ "keeper_name", `String receipt.keeper_name
    ; "expected_trace_id", `String (Keeper_id.Trace_id.to_string receipt.expected_trace_id)
    ; "operator_operation_id", `String receipt.operator_operation_id
    ; "requested_at", `Float receipt.requested_at
    ; "operation", `String "resume_owner"
    ]

let resume_result_json ~name
    (success : Keeper_paused_work_resume_transaction.success) =
  let commit_status =
    match success.commit_status with
    | Committed -> "committed"
    | Already_committed -> "already_committed"
  in
  let ok, projection, error =
    match success.projection with
    | Applied phase ->
      true, Keeper_state_machine.phase_to_string phase, None
    | Committed_followup_failed failure ->
      false, "committed_followup_failed", Some (resume_failure_message failure)
  in
  `Assoc
    ([ "ok", `Bool ok
     ; "action", `String "resume"
     ; "operation", `String "resume_owner"
     ; "name", `String name
     ; "committed", `Bool true
     ; "commit_status", `String commit_status
     ; "projection", `String projection
     ; "receipt", resume_receipt_json success.receipt
     ]
     @ match error with
       | None -> []
       | Some message -> [ "error", `String message ])

let run_resume_owner config ~name request =
  Keeper_paused_work_resume_transaction.resume config ~keeper_name:name request

let persist_directive_pause ~config ~name =
  match
    Keeper_owner_registry.apply_meta
      ~base_path:config.Workspace.base_path
      ~keeper_name:name
      (Keeper_owner_reducer.Pause
         { reason =
             Keeper_latched_reason.Operator_paused
               { operator_actor = Keeper_latched_reason.Grpc_directive }
         ; updated_at = Keeper_meta_contract.now_iso ()
         })
  with
  | Ok (Some _) -> Ok ()
  | Ok None -> Error "owner removed Keeper metadata during pause"
  | Error error ->
    let detail = Keeper_owner_registry.command_error_to_string error in
    Log.Keeper.warn
      "directive pause: owner command failed for %s: %s"
      name
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string PausedStatePersistErrors)
      ~labels:
        [ ( "phase"
          , Keeper_paused_state_persist_phase.(to_label Directive) )
        ; "reason", "owner_command_error"
        ]
      ();
    Error detail

let handle_keeper_directive_post ~sw:_ ~clock:_ state _agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_directive in
  if String.length name = 0 then
    respond_error reqd "keeper name is required"
  else
    let parsed =
      try
        let json = Yojson.Safe.from_string body_str in
        parse_keeper_directive_json json
      with Yojson.Json_error e ->
        Error (Printf.sprintf "invalid json: %s" e)
    in
    match parsed with
    | Error message -> respond_error ~ok:false reqd message
    | Ok (Resume_owner request) ->
      let config = Mcp_server.workspace_config state in
      (match run_resume_owner config ~name request with
       | Error error ->
         Log.Keeper.warn
           "directive resume_owner rejected for %s operation_id=%s: %s"
           name
           request.operator_operation_id
           (Keeper_paused_work_resume_transaction.error_to_string error);
         Http.Response.json_value
           ~status:(resume_error_status error)
           ~request:req
           (`Assoc
              [ "ok", `Bool false
              ; "action", `String "resume"
              ; "operation", `String "resume_owner"
              ; "name", `String name
              ; "committed", `Bool false
              ; "error", `String (Keeper_paused_work_resume_transaction.error_to_string error)
              ])
           reqd
       | Ok success ->
         invalidate_keeper_execution_surfaces ~config ();
         let response = resume_result_json ~name success in
         (match success.projection with
          | Applied _ ->
            Log.Keeper.info
              "directive resume_owner applied for %s operation_id=%s"
              name
              request.operator_operation_id;
            Http.Response.json_value ~compress:true ~request:req response reqd
          | Committed_followup_failed failure ->
            Log.Keeper.warn
              "directive resume_owner committed with pending projection for %s operation_id=%s: %s"
              name
              request.operator_operation_id
              (resume_failure_message failure);
            Http.Response.json_value
              ~status:`Accepted
              ~compress:true
              ~request:req
              response
              reqd))
    | Ok (Plain_directive plain_directive) ->
      let config = Mcp_server.workspace_config state in
      let action_str = plain_directive_action plain_directive in
      let directive = plain_directive_to_keeper_directive plain_directive in
      let read_result = Keeper_meta_store.read_meta config name in
      let needs_meta =
        match plain_directive with
        | Plain_pause -> true
        | Plain_wakeup -> false
      in
      let proceed meta_opt =
        let persist_result =
          match plain_directive, meta_opt with
          | Plain_pause, Some _ -> persist_directive_pause ~config ~name
          | Plain_pause, None | Plain_wakeup, _ -> Ok ()
        in
        match persist_result with
        | Error error ->
          Http.Response.json_value
            ~status:`Internal_server_error
            ~request:req
            (`Assoc
               [ "ok", `Bool false
               ; "action", `String action_str
               ; "name", `String name
               ; ( "error"
                 , `String error )
               ])
            reqd
        | Ok () ->
          let resolved_agent_name = name in
          Keeper_keepalive.process_directive
            ~agent_name:resolved_agent_name
            directive;
          (match plain_directive with
           | Plain_pause ->
             refresh_keeper_execution_surfaces
               ~config
               ~name
               (Keeper_lifecycle_events.Phase_event
                  Keeper_state_machine.Paused)
           | Plain_wakeup ->
             invalidate_keeper_execution_surfaces ~config ());
          Http.Response.json_value ~compress:true ~request:req
            (`Assoc
               [ "ok", `Bool true
               ; "action", `String action_str
               ; "name", `String name
               ])
            reqd
      in
      (match read_result, needs_meta with
       | Error error, true ->
         Log.Keeper.error
           "directive %s: read_meta failed for %s: %s"
           action_str
           name
           error;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string PausedStatePersistErrors)
           ~labels:
             [ "phase", Keeper_paused_state_persist_phase.(to_label Directive)
             ; "reason", "read_meta_error"
             ]
           ();
         Http.Response.json_value ~status:`Internal_server_error ~request:req
           (`Assoc
              [ "ok", `Bool false
              ; "action", `String action_str
              ; "name", `String name
              ; "error", `String (Printf.sprintf "read_meta failed: %s" error)
              ])
           reqd
       | Ok None, true ->
         Log.Keeper.warn
           "directive %s: keeper meta missing for %s — refusing silent no-op"
           action_str
           name;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string PausedStatePersistErrors)
           ~labels:
             [ "phase", Keeper_paused_state_persist_phase.(to_label Directive)
             ; "reason", "meta_missing"
             ]
           ();
         Http.Response.json_value ~status:`Not_found ~request:req
           (`Assoc
              [ "ok", `Bool false
              ; "action", `String action_str
              ; "name", `String name
              ; "error", `String "keeper meta not found"
              ])
           reqd
       | Error error, false ->
         Log.Keeper.warn
           "directive %s: read_meta failed for %s (best-effort proceed): %s"
           action_str
           name
           error;
         proceed None
       | Ok None, false -> proceed None
       | Ok (Some meta), _ -> proceed (Some meta))

(** Bulk variant of [handle_keeper_directive_post]. Pause and wakeup accept
    [{names: [name, ...]}]. Resume accepts exact per-owner
    [{targets: [{name, operator_operation_id}, ...]}] fences.
    Cache invalidation still runs once for the whole batch. *)
let handle_keeper_bulk_directive_post ~sw:_ ~clock:_ state _agent_name req reqd body_str =
  let parsed =
    try
      let json = Yojson.Safe.from_string body_str in
      parse_bulk_directive_json json
    with Yojson.Json_error e ->
      Error (Printf.sprintf "invalid json: %s" (String.escaped e))
  in
  match parsed with
  | Error msg ->
      Http.Response.json_value ~status:`Bad_request
        (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
        reqd
  | Ok parsed ->
      let config = Mcp_server.workspace_config state in
      let action_str, requested_count, results =
        match parsed with
        | Bulk_resume_owner targets ->
          let process_target target =
            match run_resume_owner config ~name:target.name target.request with
            | Error error ->
              `Assoc
                [ "name", `String target.name
                ; "ok", `Bool false
                ; "committed", `Bool false
                ; "error", `String (Keeper_paused_work_resume_transaction.error_to_string error)
                ]
            | Ok success -> resume_result_json ~name:target.name success
          in
          "resume", List.length targets, List.map process_target targets
        | Bulk_plain { names; directive = plain_directive } ->
          let action_str = plain_directive_action plain_directive in
          let directive = plain_directive_to_keeper_directive plain_directive in
          let needs_meta =
            match plain_directive with
            | Plain_pause -> true
            | Plain_wakeup -> false
          in
          let process_name name =
            let read_result = Keeper_meta_store.read_meta config name in
            match read_result, needs_meta with
            | Error error, true ->
              `Assoc
                [ "name", `String name
                ; "ok", `Bool false
                ; "error", `String (Printf.sprintf "read_meta failed: %s" error)
                ]
            | Ok None, true ->
              `Assoc
                [ "name", `String name
                ; "ok", `Bool false
                ; "error", `String "keeper meta not found"
                ]
            | Error _, false | Ok None, false | Ok (Some _), _ ->
              let meta_opt =
                match read_result with
                | Ok meta -> meta
                | Error _ -> None
              in
              let persist_result =
                match plain_directive, meta_opt with
                | Plain_pause, Some _ -> persist_directive_pause ~config ~name
                | Plain_pause, None | Plain_wakeup, _ -> Ok ()
              in
              (match persist_result with
               | Error error ->
                 `Assoc
                   [ "name", `String name
                   ; "ok", `Bool false
                   ; ( "error"
                     , `String error )
                   ]
               | Ok () ->
                 let resolved_agent_name = name
                 in
                 Keeper_keepalive.process_directive
                   ~agent_name:resolved_agent_name
                   directive;
                 `Assoc [ "name", `String name; "ok", `Bool true ])
          in
          action_str, List.length names, List.map process_name names
      in
      let ok_count =
        List.fold_left
          (fun acc r ->
            match Json_util.assoc_member_opt "ok" r with
            | Some (`Bool true) -> acc + 1
            | _ -> acc)
          0 results
      in
      let failed_count = requested_count - ok_count in
      let committed_count =
        List.fold_left
          (fun acc result ->
             match Json_util.assoc_member_opt "committed" result with
             | Some (`Bool true) -> acc + 1
             | _ -> acc)
          0
          results
      in
      if ok_count > 0 || committed_count > 0
      then invalidate_keeper_execution_surfaces ~config ();
      let response =
        `Assoc
          [
            ("ok", `Bool (failed_count = 0));
            ("action", `String action_str);
            ("requested", `Int requested_count);
            ("succeeded", `Int ok_count);
            ("failed", `Int failed_count);
            ("results", `List results);
          ]
      in
      if failed_count = 0 then
        Http.Response.json_value ~compress:true ~request:req response reqd
      else if committed_count > 0 then
        Http.Response.json_value ~status:`Accepted ~compress:true
          ~request:req response reqd
      else
        Http.Response.json_value ~status:`Internal_server_error ~compress:true
          ~request:req response reqd

(* RFC-0366. One sentence for one turn. The store rejects an oversized note
   rather than truncating it, and this boundary passes that refusal through
   with the caller's own byte count so an operator can see what was rejected
   instead of guessing which half arrived. *)
let handle_keeper_operator_note_post state agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_operator_note in
  if String.length name = 0 then respond_error reqd "keeper name is required"
  else
    let parsed =
      match Yojson.Safe.from_string body_str with
      | `Assoc fields ->
        (match List.assoc_opt "text" fields with
         | Some (`String text) -> Ok text
         | Some _ -> Error "text must be a string"
         | None -> Error "text is required")
      | _ -> Error "body must be a JSON object"
      | exception Yojson.Json_error message ->
        Error (Printf.sprintf "invalid json: %s" message)
    in
    match parsed with
    | Error message -> respond_error ~ok:false reqd message
    | Ok text ->
      let config = Mcp_server.workspace_config state in
      (match
         Keeper_operator_note.write ~config ~keeper:name ~text ~created_by:agent_name
       with
       | Ok note ->
         Log.Keeper.info
           "operator note stored for %s by %s bytes=%d"
           name
           agent_name
           (String.length text);
         Http.Response.json_value ~compress:true ~request:req
           (`Assoc
              [ "ok", `Bool true
              ; "keeper", `String name
              ; "pending", `Bool true
              ; "note", Keeper_operator_note.to_json note
              ])
           reqd
       | Error error ->
         let status =
           match error with
           | Keeper_operator_note.Write_failed _ -> `Internal_server_error
           | Keeper_operator_note.Unknown_keeper _
           | Keeper_operator_note.Empty_text
           | Keeper_operator_note.Too_large _ -> `Bad_request
         in
         Http.Response.json_value ~status ~request:req
           (`Assoc
              [ "ok", `Bool false
              ; "keeper", `String name
              ; ( "error"
                , `String (Keeper_operator_note.write_error_to_string error) )
              ])
           reqd)

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory. *)
