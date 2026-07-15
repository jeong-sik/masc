(** Keeper HTTP API POST handlers — config update and lifecycle. *)

module Http = Http_server_eio
module Checkpoints = Server_dashboard_http_keeper_api_checkpoints
module Trace = Server_dashboard_http_keeper_api_trace

include Server_dashboard_http_keeper_api_types

let json_list_length = function
  | `List l -> List.length l
  | _ -> 0
;;

let trajectory_line_ts = Trace.line_ts
let dedupe_thinking_lines = Trace.dedupe_thinking_lines

let read_internal_history_lines = Trace.read_internal_history_lines
let merge_keeper_trace_lines = Trace.merge_keeper_trace_lines

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

let keeper_catchup_judge_prompt ~keeper_name ~(digest : Keeper_catchup_digest.t) =
  let digest_json = Keeper_catchup_digest.to_json digest in
  Printf.sprintf
    {|You are a strict MASC activity judge.

Write the assessment in Korean. Judge only the activity digest below. Do not invent unseen messages, hidden intent, or external context.
This assessment is advisory and non-blocking: do not claim it gates merge, keeper progress, task ownership, or user access. A FAIL verdict means immediate operator attention is recommended, not an automatic stop.

Rubric:
- Outcome quality: did the keeper make observable progress, or only produce motion?
- Risk: are there failed turns, crashes, transport failures, read errors, or lower-bound coverage warnings?
- Responsiveness: do the message/turn/board/task counts suggest useful engagement?
- Improvement: name concrete next actions an operator or keeper should take.

Return concise Markdown with these sections:
1. Verdict: one of PASS, WATCH, or FAIL, with one sentence.
2. Evidence: 3-5 bullets tied to exact digest fields.
3. Improvement points: 2-4 concrete recommendations.
4. Missing evidence: note any coverage/read limitations.

Keeper: %s
Digest JSON:
```json
%s
```|}
    keeper_name
    (Yojson.Safe.pretty_to_string digest_json)
;;

let parse_fusion_result text =
  try Yojson.Safe.from_string text with
  | Yojson.Json_error _ -> `Assoc [ "ok", `Bool false; "error", `String text ]
;;

let is_finite_float value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false
;;

let handle_keeper_catchup_judge_post state req reqd body_str =
  let req_path = Http.Request.path req in
  let name = extract_keeper_name_for_suffix req_path keeper_suffix_catchup_judge in
  if name = "" then respond_error reqd "keeper name required"
  else if not (Keeper_config.validate_name name) then
    respond_error reqd (Printf.sprintf "invalid keeper name: %s" name)
  else
    try
      let args = Yojson.Safe.from_string body_str in
      let since_unix = Safe_ops.json_float_opt "since_unix" args in
      match since_unix with
      | None -> respond_error reqd "since_unix is required"
      | Some since_unix when not (is_finite_float since_unix) ->
        respond_error reqd "since_unix must be a finite unix-seconds float"
      | Some since_unix when since_unix < 0.0 ->
        respond_error reqd "since_unix must be non-negative"
      | Some since_unix ->
        let config = Mcp_server.workspace_config state in
        let now_unix = Time_compat.now () in
        let digest =
          Keeper_catchup_digest.build ~base_path:config.base_path
            ~keeper_name:name ~since_unix ~now_unix
        in
        let prompt = keeper_catchup_judge_prompt ~keeper_name:name ~digest in
        (match Eio_context.get_root_switch_opt (), Eio_context.get_net_opt () with
         | None, _ | _, None ->
           respond_error reqd "fusion requires the server root switch + net (unavailable)"
         | Some sw, Some net ->
           (match Fusion_config_loader.load ~base_path:config.base_path with
            | Error msg -> respond_error reqd msg
            | Ok policy ->
              let fusion_args =
                `Assoc
                  [ "prompt", `String prompt
                  ; "web_tools", `Bool false
                  ; "topology", `String "simple"
                  ]
              in
              let run_id = Random_id.prefixed ~prefix:"fus-" ~bytes:16 in
              let raw =
                Fusion_tool.handle
                  ~sw
                  ~net
                  ~base_dir:config.base_path
                  ~keeper:name
                  ~now_unix
                  ~run_id
                  ~policy
                  ~args:fusion_args
                  ()
              in
              let fusion_json = parse_fusion_result raw in
              (match Json_util.assoc_member_opt "ok" fusion_json with
               | Some (`Bool true) ->
                 Http.Response.json_value ~compress:true ~request:req
                   (`Assoc
                      [ "ok", `Bool true
                      ; "status", `String "fusion_started"
                      ; "run_id", `String run_id
                      ; "owner_keeper", `String name
                      ; "fusion_route", `String ("/#fusion?run_id=" ^ run_id)
                      ; "digest", Keeper_catchup_digest.to_json digest
                      ])
                   reqd
               | _ ->
                 let message =
                   match Json_util.assoc_member_opt "error" fusion_json with
                   | Some (`String msg) -> msg
                   | _ -> Yojson.Safe.to_string fusion_json
                 in
                 respond_error reqd message)))
    with
    | Yojson.Json_error msg -> respond_error reqd ("invalid json: " ^ msg)
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> respond_error reqd (Printexc.to_string exn)
;;

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
              ("manifest_total_rows_scope", `String manifest_scan.scan_scope);
              ( "manifest_total_rows_exact",
                `Bool (manifest_scan.scanned_lines < manifest_scan.scan_line_limit) );
              ("manifest_scan_line_limit", `Int manifest_scan.scan_line_limit);
              ("manifest_scanned_lines", `Int manifest_scan.scanned_lines);
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
    "compaction_message_gate";
    "compaction_token_gate";
    "compaction_cooldown_sec";
    "handoff_cooldown_sec";
  ]

let dashboard_config_float_fields =
  [
    "compaction_ratio_gate";
    "handoff_threshold";
  ]

let dashboard_config_string_list_fields =
  [
    "mention_targets";
    "allowed_paths";
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

let keeper_chat_recovery_error_status = function
  | Keeper_chat_queue.Invalid_input _ -> `Bad_request
  | Keeper_chat_queue.Receipt_already_terminal _
  | Keeper_chat_queue.Receipt_not_recovery_required _
  | Keeper_chat_queue.Recovery_revision_mismatch _
  | Keeper_chat_queue.Recovery_lease_mismatch _ ->
      `Conflict
  | Keeper_chat_queue.Persistence_not_configured
  | Keeper_chat_queue.Snapshot_unavailable _
  | Keeper_chat_queue.Revision_exhausted
  | Keeper_chat_queue.Persist_failed _ ->
      `Service_unavailable

let handle_keeper_chat_recovery_post state agent_name req reqd ~keeper_name
    ~raw_receipt_id body_str =
  let respond ?(status = `OK) json =
    Http.Response.json_value ~status ~request:req json reqd
  in
  let parsed =
    try
      Yojson.Safe.from_string body_str
      |> Keeper_chat_recovery_command.parse_request
    with
    | Yojson.Json_error detail ->
      Error
        (Keeper_chat_recovery_command.Invalid_field
           { field = "request body"; expectation = "is invalid JSON: " ^ detail })
  in
  match parsed with
  | Error error ->
    respond
      ~status:`Bad_request
      (`Assoc
        [ "schema", `String Keeper_chat_recovery_command.result_schema
        ; "ok", `Bool false
        ; "error", Keeper_chat_recovery_command.input_error_to_json error
        ])
  | Ok recovery_request ->
    (match
       Keeper_chat_recovery_command.make
         ~keeper_name
         ~raw_receipt_id
         recovery_request
     with
     | Error error ->
       respond
         ~status:`Bad_request
         (`Assoc
           [ "schema", `String Keeper_chat_recovery_command.result_schema
           ; "ok", `Bool false
           ; "error", Keeper_chat_recovery_command.input_error_to_json error
           ])
     | Ok command ->
       let result =
         Keeper_chat_recovery_command.execute ~now:(Time_compat.now ()) command
       in
       let audit =
         Keeper_chat_recovery_command.audit
           (Mcp_server.workspace_config state)
           ~actor:agent_name
           command
           ~outcome:
             (match result with
              | Ok _ -> Audit_log.Success
              | Error error ->
                Audit_log.Failure
                  (Keeper_chat_queue.mutation_error_to_string error))
         |> Keeper_chat_recovery_command.audit_json
       in
       (match result with
        | Ok report ->
          respond (Keeper_chat_recovery_command.success_json ~audit command report)
        | Error error ->
          respond
            ~status:(keeper_chat_recovery_error_status error)
            (Keeper_chat_recovery_command.mutation_error_json ~audit error)))

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
         | "compaction_message_gate" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_compaction_message_gate value
         | "compaction_token_gate" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_compaction_token_gate value
         | "compaction_cooldown_sec" ->
             validate_dashboard_normalized_int key
               Keeper_config.normalize_compaction_cooldown_sec value
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
                          publication_recovery_provider =
                            Mcp_server.publication_recovery_availability_provider state;
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

let directive_action_to_string = function
  | Keeper_directive.Pause -> "pause"
  | Keeper_directive.Resume -> "resume"
  | Keeper_directive.Wakeup -> "wakeup"
  | Keeper_directive.Assign_task _ -> "assign_task"

let keeper_ctx_of_dashboard_state ~sw ~clock state agent_name :
    _ Keeper_tool_surface.context =
  let workspace_scope = Mcp_server.workspace_scope state in
  {
    config = workspace_scope.config;
    agent_name;
    sw;
    clock;
    proc_mgr = state.Mcp_server.proc_mgr;
    net = state.Mcp_server.net;
    publication_recovery_provider =
      Mcp_server.publication_recovery_availability_provider state;
  }

let meta_with_directive_paused_state
    (meta : Keeper_meta_contract.keeper_meta)
    paused =
  let base =
    if paused
    then
      (* Pause: set the bit and drop the stale blocker; any existing latch
         stays paired with [paused = true]. *)
      { meta with paused = true; runtime = { meta.runtime with last_blocker = None } }
    else
      (* Resume: [mark_resumed] couples clearing [paused] with clearing the
         typed latch (Dead_tombstone included). Previously this path set
         [paused = false] while leaving [latched_reason], stranding the keeper
         in the un-recoverable paused=false + Dead_tombstone split that
         lifecycle admission denies forever. *)
      Keeper_meta_contract.mark_resumed meta
  in
  { base with updated_at = Keeper_meta_contract.now_iso () }

let should_persist_directive_paused_state directive (meta : Keeper_meta_contract.keeper_meta) paused =
  match directive with
  | Keeper_directive.Resume -> true
  | Keeper_directive.Pause | Keeper_directive.Wakeup
  | Keeper_directive.Assign_task _ -> not (Bool.equal meta.paused paused)

let persist_directive_paused_state ~config ~name ~action_str directive meta paused =
  let updated_meta = meta_with_directive_paused_state meta paused in
    (* Pause/resume toggle via CAS merge: do not rewind a concurrent
       turn's cumulative usage counters. *)
  match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.monotonic_usage_counters
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
        [ ( "phase"
          , Keeper_paused_state_persist_phase.(to_label Directive) )
        ; "reason", "write_meta_error"
        ]
      ();
    Error err

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
        | Some "pause" -> Ok Keeper_directive.Pause
        | Some "resume" -> Ok Keeper_directive.Resume
        | Some "wakeup" -> Ok Keeper_directive.Wakeup
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
            | Keeper_directive.Resume ->
              ensure_registered_for_resume ~sw ~clock state agent_name name
            | Keeper_directive.Pause | Keeper_directive.Wakeup
            | Keeper_directive.Assign_task _ -> Ok `Already_registered
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
                | Keeper_directive.Pause, _ -> persist_paused_state true
                | Keeper_directive.Resume, `Already_registered ->
                  persist_paused_state false
                | Keeper_directive.Resume, `Booted_missing_registry -> Ok ()
                | Keeper_directive.Wakeup, _
                | Keeper_directive.Assign_task _, _ -> Ok ()
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
                    ~agent_name:resolved_agent_name directive;
                  (match directive with
                   | Keeper_directive.Pause ->
                     refresh_keeper_execution_surfaces ~config ~name "paused"
                   | Keeper_directive.Resume ->
                       refresh_keeper_execution_surfaces ~config ~name "resumed"
                   | Keeper_directive.Wakeup
                   | Keeper_directive.Assign_task _ ->
                     invalidate_keeper_execution_surfaces ~config ());
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
          | Keeper_directive.Pause | Keeper_directive.Resume -> true
          | Keeper_directive.Wakeup | Keeper_directive.Assign_task _ -> false
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
        | Some "pause" -> Ok Keeper_directive.Pause
        | Some "resume" -> Ok Keeper_directive.Resume
        | Some "wakeup" -> Ok Keeper_directive.Wakeup
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
        match directive with
        | Keeper_directive.Pause | Keeper_directive.Resume -> true
        | Keeper_directive.Wakeup | Keeper_directive.Assign_task _ -> false
      in
      let process_one name =
        let read_result = Keeper_meta_store.read_meta config name in
        let meta_opt =
          match read_result with
          | Ok (Some m) -> Some m
          | Ok None | Error _ -> None
        in
        match read_result, needs_meta with
        | Error err, true ->
            `Assoc
              [
                ("name", `String name);
                ("ok", `Bool false);
                ( "error",
                  `String (Printf.sprintf "read_meta failed: %s" err) );
              ]
        | Ok None, true ->
            `Assoc
              [
                ("name", `String name);
                ("ok", `Bool false);
                ("error", `String "keeper meta not found");
              ]
        | Error _, false | Ok None, false | Ok (Some _), _ ->
            let target_paused =
              match directive with
              | Keeper_directive.Pause -> Some true
              | Keeper_directive.Resume -> Some false
              | Keeper_directive.Wakeup | Keeper_directive.Assign_task _ -> None
            in
            (match
               match directive with
               | Keeper_directive.Resume ->
                 ensure_registered_for_resume ~sw ~clock state agent_name name
               | Keeper_directive.Pause | Keeper_directive.Wakeup
               | Keeper_directive.Assign_task _ -> Ok `Already_registered
             with
             | Error err ->
                 `Assoc
                   [ ("name", `String name); ("ok", `Bool false); ("error", `String err) ]
             | Ok registration_state ->
                 let persist_result =
                   match directive, registration_state, target_paused, meta_opt with
                   | Keeper_directive.Resume, `Booted_missing_registry, _, _ -> Ok ()
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
                      `Assoc
                        [
                          ("name", `String name);
                          ("ok", `Bool false);
                          ("error", `String err);
                        ]
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
                        ~agent_name:resolved_agent_name directive;
                      `Assoc [ ("name", `String name); ("ok", `Bool true) ]))
      in
      let results = List.map process_one names in
      let ok_count =
        List.fold_left
          (fun acc r ->
            match Json_util.assoc_member_opt "ok" r with
            | Some (`Bool true) -> acc + 1
            | _ -> acc)
          0 results
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
            ("results", `List results);
          ]
      in
      if failed_count = 0 then
        Http.Response.json_value ~compress:true ~request:req response reqd
      else
        Http.Response.json_value ~status:`Internal_server_error ~compress:true
          ~request:req response reqd

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory. *)
