(** Keeper HTTP API POST handlers — tool policy, config update, lifecycle. *)

module Http = Http_server_eio
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Trace = Server_dashboard_http_keeper_api_trace

include Server_dashboard_http_keeper_api_types

let dedupe_tool_names names =
  Json_util.dedupe_keep_order
    (names |> List.map String.trim |> List.filter (fun name -> name <> ""))

(* RFC-0273 §3.1 — names newly added to a keeper's tool_access (not already
   present) that are not known candidate tools.

   Returned names are the ones a write should reject instead of persisting
   silently: the runtime drops unknown tool_access entries at
   [Keeper_tool_policy.tool_access_lookup_of_meta], so without this check an
   operator typo is accepted then silently ignored (AI anti-pattern §2). The
   check is delta-only — names already on the keeper are grandfathered so a
   legacy keeper carrying a stale/renamed name can still be edited. Membership
   is raw against [candidate_names] (no alias expansion), matching the runtime
   keep-rule exactly; [candidate_names] already includes core tools via
   effective_core_tools, so no separate core bypass is needed. tool_denylist is
   intentionally not validated here: denying an unknown name is a harmless no-op
   and the denylist is alias-expanded, so a strict check would false-reject. *)
let unknown_added_tool_names ~candidate_names ~existing ~requested =
  requested
  |> List.filter (fun name -> not (List.mem name existing))
  |> List.filter (fun name -> not (List.mem name candidate_names))

let json_list_length = function
  | `List l -> List.length l
  | _ -> 0
;;

let trajectory_line_ts = Trace.line_ts
let dedupe_thinking_lines = Trace.dedupe_thinking_lines

let read_internal_history_lines = Trace.read_internal_history_lines
let merge_keeper_trace_lines = Trace.merge_keeper_trace_lines

let keeper_tools_response_json (meta : Keeper_meta_contract.keeper_meta) =
  let allowed = Keeper_tool_dispatch_runtime.keeper_allowed_tool_names meta in
  let masc_count = List.length (Keeper_tool_dispatch_runtime.keeper_masc_tool_names meta) in
  `Assoc
    [
      ("ok", `Bool true);
      ("tool_access", Json_util.json_string_list meta.tool_access);
      ("resolved_allowlist", `List (List.map (fun s -> `String s) allowed));
      ("tool_denylist", `List (List.map (fun s -> `String s) meta.tool_denylist));
      ("active_masc_tool_count", `Int masc_count);
      ("total_active", `Int (List.length allowed));
    ]

let error_json ?ok message =
  let fields = [ ("error", `String message) ] in
  let fields =
    match ok with
    | None -> fields
    | Some value -> ("ok", `Bool value) :: fields
  in
  `Assoc fields

let respond_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http.Response.json_value ?request ~status (error_json ?ok message) reqd

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
      respond_error reqd "keeper name required"
    else
      let config = (Mcp_server.workspace_config state) in
      match Keeper_meta_store.read_meta config name with
      | Error msg -> respond_error ~status:`Not_found reqd msg
      | Ok None -> respond_error ~status:`Not_found reqd (Printf.sprintf "keeper %S not found" name)
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
                     match Json_util.assoc_member_opt "tool_access" args with
                     | Some (`List _ as access_json) ->
                         Keeper_meta_contract.tool_access_of_meta_json
                           (`Assoc [ ("tool_access", access_json) ])
                     | Some `Null -> Error "tool_access required"
                     | None | Some _ -> Error "tool_access must be an array of strings"
                   in
                   Result.bind tool_access_result (fun tool_access ->
                     let lookup = Keeper_tool_policy.tool_access_lookup_of_meta meta in
                     match
                       unknown_added_tool_names
                         ~candidate_names:lookup.Keeper_tool_policy.candidate_names
                         ~existing:meta.tool_access ~requested:tool_access
                     with
                     | [] ->
                         Ok
                           {
                             meta with
                             tool_access;
                             tool_denylist = deny;
                             updated_at = Keeper_meta_contract.now_iso ();
                           }
                     | unknown ->
                         Error
                           (Printf.sprintf "unknown tool name(s) in tool_access: %s"
                              (String.concat ", " unknown)))
               | "" -> Error "action required (set_policy)"
               | other -> Error (Printf.sprintf "unknown action: %s" other)
             in
             (match updated_meta with
             | Error msg ->
                 respond_error reqd msg
             | Ok meta' ->
                 (* User-initiated tool config wins for its edited fields, but
                    persist via CAS merge so a concurrent keeper turn's
                    cumulative usage counters are not rewound by this
                    snapshot-derived write. *)
                 (match
                    Keeper_meta_store.write_meta_with_merge
                      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                      config meta'
                  with
                  | Ok () ->
                      Dashboard_cache.invalidate
                        (keeper_config_cache_key config name);
                      Http.Response.json_value ~compress:true ~request:req
                        (keeper_tools_response_json meta') reqd
                  | Error e ->
                      respond_error ~status:`Internal_server_error reqd
                        (Printf.sprintf "write failed: %s" e)))
           with Yojson.Json_error e ->
             respond_error reqd (Printf.sprintf "invalid json: %s" e)))

(* Trajectory preview helpers moved to Server_dashboard_http_keeper_api_types. *)

let stat_json_of_path = Checkpoints.stat_json_of_path
let oas_checkpoint_summary_json = Checkpoints.oas_checkpoint_summary_json
let keeper_checkpoint_inventory_json = Checkpoints.inventory_json

let linked_artifact_json = Checkpoints.linked_artifact_json

include Server_dashboard_http_keeper_runtime_manifest_scan

(* Runtime-manifest receipt + scan-summary helpers in Server_dashboard_http_keeper_api_scan_summary. *)
module Scan_summary = Server_dashboard_http_keeper_api_scan_summary

let receipt_row_matches = Scan_summary.receipt_row_matches
let read_receipt_rows_with_read_errors = Scan_summary.read_receipt_rows_with_read_errors
let read_receipt_rows = Scan_summary.read_receipt_rows
let unique_ints = Scan_summary.unique_ints
let json_int_list = Scan_summary.json_int_list
let event_bus_summary_json = Scan_summary.event_bus_summary_json

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
      | Some value -> String_util.trim_to_option value
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
        let receipts, receipt_read_errors =
          read_receipt_rows_with_read_errors ~keeper_name:name ~trace_id ?turn_id receipt_paths
        in
        let receipts =
          receipts
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
          else if receipts = [] && receipt_read_errors <> [] then
            ("partial", Some "receipt_read_error")
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
              ("manifest_total_rows_scope", `String manifest_scan.scan_scope);
              ( "manifest_total_rows_exact",
                `Bool (manifest_scan.scanned_lines < manifest_scan.scan_line_limit) );
              ("manifest_scan_line_limit", `Int manifest_scan.scan_line_limit);
              ("manifest_scanned_lines", `Int manifest_scan.scanned_lines);
              ("manifest_returned_rows", `Int (List.length manifest_rows));
              ("receipt_returned_rows", `Int (List.length receipts));
              ("receipt_read_error_count", `Int (List.length receipt_read_errors));
              ("receipt_read_errors", `List receipt_read_errors);
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
    respond_error ~ok:false reqd "keeper name is required"
  else
    let config = (Mcp_server.workspace_config state) in
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
                   Keeper_checkpoint_store.delete_oas_history_files
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
    "goal";
    "instructions";
    "compaction_profile";
    "sandbox_profile";
    "network_mode";
  ]

let dashboard_config_bool_fields =
  [
    "autoboot_enabled";
    "proactive_enabled";
    "auto_handoff";
  ]

let dashboard_config_int_fields =
  [
    "proactive_idle_sec";
    "proactive_cooldown_sec";
    "compaction_message_gate";
    "compaction_token_gate";
    "continuity_compaction_cooldown_sec";
    "handoff_cooldown_sec";
  ]

let dashboard_config_float_fields =
  [
    "compaction_ratio_gate";
    "handoff_threshold";
  ]

let dashboard_config_string_list_fields =
  [
    "active_goal_ids";
    "mention_targets";
    "allowed_paths";
    "tool_access";
    "tool_denylist";
  ]

let dashboard_config_patch_allowed_fields =
  [ "name"; "max_context_override" ]
  @
  dashboard_config_string_fields
  @ dashboard_config_bool_fields
  @ dashboard_config_int_fields
  @ dashboard_config_float_fields
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

let validate_dashboard_normalized_int key normalize value =
  let normalized = normalize value in
  if normalized = value then Ok ()
  else
    Error
      (Printf.sprintf "%s is out of range for dashboard config: %d" key value)

let validate_dashboard_normalized_float key normalize value =
  let normalized = normalize value in
  if normalized = value then Ok ()
  else
    Error
      (Printf.sprintf "%s is out of range for dashboard config: %g" key value)

let validate_dashboard_nonnegative_int key value =
  if value >= 0 then Ok ()
  else
    Error
      (Printf.sprintf "%s must be non-negative (received %d)" key value)

let validate_dashboard_max_context_override = function
  | `Null -> Ok ()
  | `Int value ->
      let min_context = Keeper_config.min_keeper_context_tokens in
      let max_context = Keeper_config.max_keeper_context_tokens in
      if value >= min_context && value <= max_context then Ok ()
      else
        Error
          (Printf.sprintf
             "max_context_override must be within %d..%d tokens (received %d)"
             min_context max_context value)
  | other -> dashboard_field_type_error "max_context_override" "an integer or null" other

let validate_dashboard_config_field key value =
  if key = "name" then
    match value with
    | `String _ -> Ok ()
    | other -> dashboard_field_type_error key "a string" other
  else if key = "max_context_override" then
    validate_dashboard_max_context_override value
  else if List.mem key dashboard_config_string_fields then
    match value with
    | `String _ -> Ok ()
    | other -> dashboard_field_type_error key "a string" other
  else if List.mem key dashboard_config_bool_fields then
    match value with
    | `Bool _ -> Ok ()
    | other -> dashboard_field_type_error key "a boolean" other
  else if List.mem key dashboard_config_int_fields then
    match value with
    | `Int value ->
        (match key with
         | "proactive_idle_sec" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_proactive_idle_sec value
         | "proactive_cooldown_sec" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_proactive_cooldown_sec value
         | "compaction_message_gate" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_compaction_message_gate value
         | "compaction_token_gate" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_compaction_token_gate value
         | "continuity_compaction_cooldown_sec" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_continuity_compaction_cooldown_sec value
         | "handoff_cooldown_sec" ->
             validate_dashboard_nonnegative_int key value
         | _ -> Ok ())
    | other -> dashboard_field_type_error key "an integer" other
  else if List.mem key dashboard_config_float_fields then
    match value with
    | `Int value ->
        let f = float_of_int value in
        if key = "handoff_threshold" then
          if f >= 0.0 && f <= 1.0 then Ok ()
          else Error "handoff_threshold must be within 0.0..1.0"
        else
          validate_dashboard_normalized_float key
            Keeper_config.normalize_compaction_ratio_gate f
    | `Float value ->
        if key = "handoff_threshold" then
          if value >= 0.0 && value <= 1.0 then Ok ()
          else Error "handoff_threshold must be within 0.0..1.0"
        else
          validate_dashboard_normalized_float key
            Keeper_config.normalize_compaction_ratio_gate value
    | other -> dashboard_field_type_error key "a number" other
  else if List.mem key dashboard_config_string_list_fields then
    validate_dashboard_string_list_field key value
  else Ok ()

let validate_dashboard_tool_access_update ~meta fields =
  match List.assoc_opt "tool_access" fields with
  | None -> Ok ()
  | Some access_json ->
      (match
         Keeper_meta_contract.tool_access_of_meta_json
           (`Assoc [ ("tool_access", access_json) ])
       with
       | Error msg -> Error msg
       | Ok requested ->
           let lookup = Keeper_tool_policy.tool_access_lookup_of_meta meta in
           (match
              unknown_added_tool_names
                ~candidate_names:lookup.Keeper_tool_policy.candidate_names
                ~existing:meta.tool_access
                ~requested
            with
            | [] -> Ok ()
            | unknown ->
                Error
                  (Printf.sprintf "unknown tool name(s) in tool_access: %s"
                     (String.concat ", " unknown))))

let validate_dashboard_config_patch ~meta fields =
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
         | Ok () -> validate_dashboard_tool_access_update ~meta fields)

let handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_config in
  if String.length name = 0 then
    respond_error reqd "keeper name is required"
  else
    let config = (Mcp_server.workspace_config state) in
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
                        }
                      in
                      (match
                         Keeper_turn_up_args.parse
                           ~allow_sandbox_fields:true keeper_ctx args_with_name
                       with
                       | Error result ->
                           respond_error reqd
                             (Keeper_types_profile.tool_result_body result)
                       | Ok parsed ->
                           (* Dashboard edits are user-initiated and win for the
                              fields they touch; update_keeper now persists via
                              a CAS merge ([heartbeat_fields_from_disk]) so a
                              concurrent keeper turn's cumulative usage counters
                              are not rewound by this snapshot-derived write.
                              [preserve_prompt_defaults] keeps existing prompt
                              fields when the request omits them. *)
                           let result =
                             Keeper_turn_up_update.update_keeper
                               ~preserve_prompt_defaults:true keeper_ctx parsed
                               meta0
                           in
                           if not
                                (Keeper_types_profile.tool_result_success result)
                           then
                             respond_error reqd
                               (Keeper_types_profile.tool_result_body result)
                           else (
                             Dashboard_cache.invalidate
                               (keeper_config_cache_key config name);
                             let (_st, json) =
                               Dashboard_http_keeper.keeper_config_json config
                                 name
                             in
                             Http.Response.json_value ~compress:true
                               ~request:req json reqd)))
           | None ->
               respond_error reqd "request body must be a JSON object"
         with Yojson.Json_error e ->
           respond_error reqd (Printf.sprintf "invalid json: %s" e))

let handle_keeper_lifecycle_post =
  Server_dashboard_http_keeper_api_lifecycle_post.handle_keeper_lifecycle_post

let directive_action_to_string = function
  | `Pause -> "pause"
  | `Resume -> "resume"
  | `Wakeup -> "wakeup"

let keeper_ctx_of_dashboard_state ~sw ~clock state agent_name :
    _ Keeper_tool_surface.context =
  {
    config = Mcp_server.workspace_config state;
    agent_name;
    sw;
    clock;
    proc_mgr = state.Mcp_server.proc_mgr;
    net = state.Mcp_server.net;
  }

let meta_with_directive_paused_state ~(config : Workspace.config) directive meta paused =
  let paused_meta (source_meta : Keeper_meta_contract.keeper_meta) =
    {
      source_meta with
      paused;
      auto_resume_after_sec = None;
      runtime = { source_meta.runtime with last_blocker = None };
      updated_at = Keeper_meta_contract.now_iso ();
    }
  in
  match directive with
  | `Resume ->
    (match
       Keeper_unified_turn_no_progress.clear_for_operator_resume
         ~base_path:config.base_path
         meta
     with
     | Ok source_meta -> Ok (paused_meta source_meta)
     | Error _ as err -> err)
  | `Pause | `Wakeup -> Ok (paused_meta meta)

let should_persist_directive_paused_state directive (meta : Keeper_meta_contract.keeper_meta) paused =
  match directive with
  | `Resume -> true
  | `Pause | `Wakeup -> not (Bool.equal meta.paused paused)

type bulk_directive_meta_read_status =
  | Bulk_directive_meta_present of Keeper_meta_contract.keeper_meta
  | Bulk_directive_meta_missing
  | Bulk_directive_meta_read_error of string

let bulk_directive_meta_read_status_of_result = function
  | Ok (Some meta) -> Bulk_directive_meta_present meta
  | Ok None -> Bulk_directive_meta_missing
  | Error err -> Bulk_directive_meta_read_error err

let bulk_directive_meta_opt = function
  | Bulk_directive_meta_present meta -> Some meta
  | Bulk_directive_meta_missing
  | Bulk_directive_meta_read_error _ ->
      None

let bulk_directive_meta_read_status_label = function
  | Bulk_directive_meta_present _ -> "present"
  | Bulk_directive_meta_missing -> "missing"
  | Bulk_directive_meta_read_error _ -> "read_error"

let bulk_directive_meta_read_fields status =
  let fields =
    [
      ( "meta_read_status",
        `String (bulk_directive_meta_read_status_label status) );
    ]
  in
  match status with
  | Bulk_directive_meta_read_error err ->
      fields @ [ ("meta_read_error", `String err) ]
  | Bulk_directive_meta_present _
  | Bulk_directive_meta_missing ->
      fields

let bulk_directive_result_json meta_read_status ~name ~ok ?error () =
  let fields =
    [ ("name", `String name); ("ok", `Bool ok) ]
    @ bulk_directive_meta_read_fields meta_read_status
  in
  let fields =
    match error with
    | None -> fields
    | Some err -> fields @ [ ("error", `String err) ]
  in
  `Assoc fields

let bulk_directive_result_has_meta_read_error = function
  | _, Bulk_directive_meta_read_error _ -> true
  | _ -> false

let persist_directive_paused_state ~config ~name ~action_str directive meta paused =
  match meta_with_directive_paused_state ~config directive meta paused with
  | Error err ->
      Log.Keeper.warn
        "directive %s: no_progress resume clear failed for %s: %s"
        action_str
        name
        err;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PausedStatePersistErrors)
        ~labels:
          [
            ( "phase",
              Keeper_paused_state_persist_phase.(to_label Directive) );
            ("reason", "no_progress_clear_error");
          ]
        ();
      Error err
  | Ok updated_meta ->
    (* Pause/resume toggle via CAS merge: do not rewind a concurrent
       turn's cumulative usage counters. *)
    (match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config
         updated_meta
     with
     | Ok () -> Ok ()
     | Error err ->
       Log.Keeper.warn
         "directive %s: write_meta failed for %s: %s"
         action_str
         name
         err;
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string PausedStatePersistErrors)
         ~labels:
           [
             ( "phase",
               Keeper_paused_state_persist_phase.(to_label Directive) );
             ("reason", "write_meta_error");
           ]
         ();
       Error err)

let ensure_registered_for_resume ~sw ~clock state agent_name name =
  let config = Mcp_server.workspace_config state in
  match Keeper_registry.get ~base_path:config.base_path name with
  | Some _ -> Ok `Already_registered
  | None ->
      let keeper_ctx = keeper_ctx_of_dashboard_state ~sw ~clock state agent_name in
      let args = `Assoc [ ("name", `String name) ] in
      (match Keeper_tool_surface.dispatch keeper_ctx ~name:"masc_keeper_up" ~args with
       | Some result when Tool_result.is_success result ->
           (match Keeper_registry.get ~base_path:config.base_path name with
            | Some _ -> Ok `Booted_missing_registry
            | None ->
                Error
                  (Printf.sprintf
                     "resume boot for %s succeeded but no registry entry was created"
                     name))
       | Some result -> Error (Tool_result.message result)
       | None -> Error "masc_keeper_up dispatch returned None")

let handle_keeper_directive_post ~sw ~clock state agent_name req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_post req_path keeper_suffix_directive in
  if String.length name = 0 then
    respond_error reqd "keeper name is required"
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
        Error (Printf.sprintf "invalid json: %s" e)
    in
  match action with
  | Error msg ->
      respond_error ~ok:false reqd msg
    | Ok directive ->
        let config = (Mcp_server.workspace_config state) in
        let action_str = directive_action_to_string directive in
        (* Issue #8391 HIGH #1: split [Ok None] (meta vanished) from [Error _]
           (IO/parse failure). For pause/resume the operator expects state to
           change; silent 200 hides the failure. For wakeup we preserve the
           prior best-effort semantics (wakeup does not require meta). *)
        let read_result = Keeper_meta_store.read_meta config name in
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
          | Some meta
            when should_persist_directive_paused_state directive meta paused ->
              persist_directive_paused_state
                ~config
                ~name
                ~action_str
                directive
                meta
                paused
          | Some _ | None -> Ok ()
        in
        let proceed () =
          let ensure_result =
            match directive with
            | `Resume -> ensure_registered_for_resume ~sw ~clock state agent_name name
            | `Pause | `Wakeup -> Ok `Already_registered
          in
          match ensure_result with
          | Error err ->
              Log.Keeper.error
                "directive %s: failed to ensure registered keeper for %s: %s"
                action_str
                name
                err;
              Http.Response.json_value ~status:`Internal_server_error ~request:req
                (`Assoc
                   [
                     ("ok", `Bool false);
                     ("action", `String action_str);
                     ("name", `String name);
                     ("error", `String err);
                   ])
                reqd
          | Ok registration_state ->
              let persist_result =
                match directive, registration_state with
                | `Pause, _ -> persist_paused_state true
                | `Resume, `Already_registered -> persist_paused_state false
                | `Resume, `Booted_missing_registry -> Ok ()
                | `Wakeup, _ -> Ok ()
              in
              (match persist_result with
              | Error err ->
                  Log.Keeper.error
                    "directive %s: failed to persist paused state for %s: %s"
                    action_str
                    name
                    err;
                  Http.Response.json_value
                    ~status:`Internal_server_error
                    ~request:req
                    (`Assoc
                       [
                         ("ok", `Bool false);
                         ("action", `String action_str);
                         ("name", `String name);
                         ("error", `String err);
                       ])
                    reqd
              | Ok () ->
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
                   | `Resume ->
                       refresh_keeper_execution_surfaces ~config ~name "resumed"
                   | `Wakeup -> invalidate_keeper_execution_surfaces ~config ());
                  Http.Response.json_value ~compress:true ~request:req
                    (`Assoc
                       [
                         ("ok", `Bool true);
                         ("action", `String action_str);
                         ("name", `String name);
                       ])
                    reqd)
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
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string PausedStatePersistErrors)
               ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Directive));
                        ("reason", "read_meta_error")]
               ();
             Http.Response.json_value ~status:`Internal_server_error ~request:req
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("action", `String action_str);
                    ("name", `String name);
                    ("error", `String (Printf.sprintf "read_meta failed: %s" err));
                  ])
               reqd
         | Ok None, true ->
             Log.Keeper.warn
               "directive %s: keeper meta missing for %s — refusing silent no-op"
               action_str
               name;
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string PausedStatePersistErrors)
               ~labels:[("phase", Keeper_paused_state_persist_phase.(to_label Directive));
                        ("reason", "meta_missing")]
               ();
             Http.Response.json_value ~status:`Not_found ~request:req
               (`Assoc
                  [
                    ("ok", `Bool false);
                    ("action", `String action_str);
                    ("name", `String name);
                    ("error", `String "keeper meta not found");
                  ])
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

(** Bulk variant of [handle_keeper_directive_post].
    Accepts [{names: [name, ...], action: "pause"|"resume"|"wakeup"}].
    Each keeper goes through the same meta read / persist / dispatch path
    as the per-name handler, but cache invalidation runs once at the end.
    This avoids N round-trip latency and N×cache-rebuild cost when an
    operator wants to (re)pause the whole fleet from the dashboard.
    @since 0.20.0 *)
let handle_keeper_bulk_directive_post ~sw ~clock state agent_name req reqd body_str =
  let parsed =
    try
      let json = Yojson.Safe.from_string body_str in
      let names_list =
        match Json_util.assoc_member_opt "names" json with
        | Some (`List items) ->
            List.filter_map
              (function
                | `String s when is_valid_keeper_name s -> Some s
                | _ -> None)
              items
            |> List.sort_uniq String.compare
        | None | Some _ -> []
      in
      let action_result =
        match Safe_ops.json_string_opt "action" json with
        | Some "pause" -> Ok `Pause
        | Some "resume" -> Ok `Resume
        | Some "wakeup" -> Ok `Wakeup
        | Some a ->
            Error
              (Printf.sprintf
                 "invalid action %S: expected pause, resume, or wakeup" a)
        | None -> Error "missing \"action\" field"
      in
      match action_result with
      | Error e -> Error e
      | Ok _ when names_list = [] ->
          Error "names must be a non-empty list of valid keeper names"
      | Ok action -> Ok (names_list, action)
    with Yojson.Json_error e ->
      Error (Printf.sprintf "invalid json: %s" (String.escaped e))
  in
  match parsed with
  | Error msg ->
      Http.Response.json_value ~status:`Bad_request
        (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
        reqd
  | Ok (names, directive) ->
      let config = (Mcp_server.workspace_config state) in
      let action_str = directive_action_to_string directive in
      let needs_meta =
        match directive with `Pause | `Resume -> true | `Wakeup -> false
      in
      let process_one name =
        let read_result = Keeper_meta_store.read_meta config name in
        let meta_read_status =
          bulk_directive_meta_read_status_of_result read_result
        in
        let meta_opt = bulk_directive_meta_opt meta_read_status in
        let result_row ~ok ?error () =
          ( bulk_directive_result_json meta_read_status ~name ~ok ?error ()
          , meta_read_status )
        in
        let proceed () =
            let target_paused =
              match directive with
              | `Pause -> Some true
              | `Resume -> Some false
              | `Wakeup -> None
            in
            (match
               match directive with
               | `Resume -> ensure_registered_for_resume ~sw ~clock state agent_name name
               | `Pause | `Wakeup -> Ok `Already_registered
             with
             | Error err ->
                 result_row ~ok:false ~error:err ()
             | Ok registration_state ->
                 let persist_result =
                   match directive, registration_state, target_paused, meta_opt with
                   | `Resume, `Booted_missing_registry, _, _ -> Ok ()
                   | _, _, Some target, Some meta
                     when should_persist_directive_paused_state directive meta target
                     ->
                       persist_directive_paused_state
                         ~config
                         ~name
                         ~action_str
                         directive
                         meta
                         target
                   | _ -> Ok ()
                 in
                 (match persist_result with
                  | Error err ->
                      result_row ~ok:false ~error:err ()
                  | Ok () ->
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
                      result_row ~ok:true ()))
        in
        match meta_read_status, needs_meta with
        | Bulk_directive_meta_read_error err, true ->
            result_row
              ~ok:false
              ~error:(Printf.sprintf "read_meta failed: %s" err)
              ()
        | Bulk_directive_meta_missing, true ->
            result_row ~ok:false ~error:"keeper meta not found" ()
        | Bulk_directive_meta_read_error err, false ->
            Log.Keeper.warn
              "bulk directive %s: read_meta failed for %s (best-effort proceed): %s"
              action_str
              name
              err;
            proceed ()
        | Bulk_directive_meta_missing, false
        | Bulk_directive_meta_present _, _ ->
            proceed ()
      in
      let result_rows = List.map process_one names in
      let results = List.map fst result_rows in
      let ok_count =
        List.fold_left
          (fun acc r ->
            match Json_util.assoc_member_opt "ok" r with
            | Some (`Bool true) -> acc + 1
            | _ -> acc)
          0 results
      in
      let meta_read_error_count =
        List.fold_left
          (fun acc row ->
             if bulk_directive_result_has_meta_read_error row then acc + 1 else acc)
          0
          result_rows
      in
      let requested_count = List.length names in
      let failed_count = requested_count - ok_count in
      if ok_count > 0 then invalidate_keeper_execution_surfaces ~config ();
      let response =
        `Assoc
          [
            ("ok", `Bool (failed_count = 0));
            ("action", `String action_str);
            ("requested", `Int requested_count);
            ("succeeded", `Int ok_count);
            ("failed", `Int failed_count);
            ("meta_read_error_count", `Int meta_read_error_count);
            ("results", `List results);
          ]
      in
      if failed_count = 0 then
        Http.Response.json_value ~compress:true ~request:req response reqd
      else
        Http.Response.json_value ~status:`Internal_server_error ~compress:true
          ~request:req response reqd

module For_testing = struct
  let bulk_directive_meta_read_error_result_json
        ~name
        ~ok
        ?error
        ~meta_read_error
        ()
    =
    bulk_directive_result_json
      (Bulk_directive_meta_read_error meta_read_error)
      ~name
      ~ok
      ?error
      ()
end

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory. *)
