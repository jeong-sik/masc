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
    "active_goal_ids";
    "mention_targets";
    "allowed_paths";
  ]

(* Control field (not persisted): explicit acknowledgement that reducing
   [max_context_override] may force a compaction. Stripped before the config is
   parsed/applied. RFC context: reactive Provider_overflow death-spiral
   (#25062/#25268) — a silent shrink converts a settings edit into a next-turn
   overflow. *)
let confirm_context_shrink_field = "confirm_context_shrink"

let dashboard_config_patch_allowed_fields =
  [ "name"; "max_context_override"; confirm_context_shrink_field ]
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
  else if key = "max_context_override" then
    validate_dashboard_max_context_override value
  else if key = confirm_context_shrink_field then
    (match value with
     | `Bool _ -> Ok ()
     | other -> dashboard_field_type_error key "a boolean" other)
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
                      in
                      (match context_shrink_of_patch ~meta:meta0 fields with
                       | Some (previous, new_v) when not confirm_context_shrink ->
                           respond_error reqd
                             (Printf.sprintf
                                "reducing max_context_override (%s -> %d) can push \
                                 this keeper's existing context past the new window \
                                 and force a compaction on its next turn. Re-send \
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
                               ~request:req json reqd))))
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
  match
    Safe_ops.json_int_opt "owner_generation" json,
    Safe_ops.json_string_opt "operator_operation_id" json
  with
  | Some owner_generation, Some operator_operation_id ->
    Ok
      Keeper_paused_work_resume_transaction.
        { owner_generation; operator_operation_id }
  | None, _ -> Error "resume requires integer \"owner_generation\""
  | _, None -> Error "resume requires string \"operator_operation_id\""

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
  let parse_resume_request json =
    match parse_keeper_directive_json json with
    | Ok (Resume_owner request) ->
      Ok (request.owner_generation, request.operator_operation_id)
    | Ok (Plain_directive _) -> Error "request is not Resume_owner"
    | Error _ as error -> error
  ;;

  let parse_bulk_resume_requests json =
    match parse_bulk_directive_json json with
    | Ok (Bulk_resume_owner targets) ->
      Ok
        (List.map
           (fun target ->
              ( target.name
              , target.request.owner_generation
              , target.request.operator_operation_id ))
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
  | Durable_owner_generation_changed _
  | Durable_owner_identity_changed
  | Durable_owner_not_paused
  | Durable_owner_dead_tombstone
  | Registry_owner_generation_changed _
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
    ; "expected_generation", `Int receipt.expected_generation
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

let persist_directive_pause ~config ~name
    (meta : Keeper_meta_contract.keeper_meta) =
  let updated_meta =
    { meta with
      paused = true
    ; runtime = { meta.runtime with last_blocker = None }
    ; updated_at = Keeper_meta_contract.now_iso ()
    }
  in
  (* Pause toggle via CAS merge: do not rewind a concurrent turn's cumulative
     usage counters. Resume is owned exclusively by the receipt transaction. *)
  match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.monotonic_usage_counters
         config
         updated_meta
  with
  | Ok () -> Ok ()
  | Error err ->
    Log.Keeper.warn
      "directive pause: write_meta failed for %s: %s"
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
           "directive resume_owner rejected for %s generation=%d operation_id=%s: %s"
           name
           request.owner_generation
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
         refresh_keeper_execution_surfaces ~config ~name "resume_owner";
         let response = resume_result_json ~name success in
         (match success.projection with
          | Applied _ ->
            Log.Keeper.info
              "directive resume_owner applied for %s generation=%d operation_id=%s"
              name
              request.owner_generation
              request.operator_operation_id;
            Http.Response.json_value ~compress:true ~request:req response reqd
          | Committed_followup_failed failure ->
            Log.Keeper.warn
              "directive resume_owner committed with pending projection for %s generation=%d operation_id=%s: %s"
              name
              request.owner_generation
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
          | Plain_pause, Some meta ->
            persist_directive_pause ~config ~name meta
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
               ; "error", `String error
               ])
            reqd
        | Ok () ->
          let resolved_agent_name =
            match Keeper_registry_lookup.find_by_name name, meta_opt with
            | Some entry, _ -> entry.meta.agent_name
            | None, Some meta -> meta.agent_name
            | None, None -> Keeper_identity.keeper_agent_name name
          in
          Keeper_keepalive.process_directive
            ~agent_name:resolved_agent_name
            directive;
          (match plain_directive with
           | Plain_pause ->
             refresh_keeper_execution_surfaces ~config ~name "paused"
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
    [{targets: [{name, owner_generation, operator_operation_id}, ...]}] fences.
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
                | Plain_pause, Some meta ->
                  persist_directive_pause ~config ~name meta
                | Plain_pause, None | Plain_wakeup, _ -> Ok ()
              in
              (match persist_result with
               | Error error ->
                 `Assoc
                   [ "name", `String name
                   ; "ok", `Bool false
                   ; "error", `String error
                   ]
               | Ok () ->
                 let resolved_agent_name =
                   match Keeper_registry_lookup.find_by_name name, meta_opt with
                   | Some entry, _ -> entry.meta.agent_name
                   | None, Some meta -> meta.agent_name
                   | None, None -> Keeper_identity.keeper_agent_name name
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

(** Keeper GET sub-routes handler: /config, /chat/history, /trajectory. *)
