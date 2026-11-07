(* server_routes_http_routes_dashboard — dashboard route registration.

   Setup (module aliases, helpers, handlers) and telemetry endpoint
   extracted to Server_routes_http_routes_dashboard_setup as part of
   godfile near-threshold split. *)

open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream
module Runtime_request = Server_dashboard_runtime_request

include Server_routes_http_routes_dashboard_setup

module Official_client_session = Server_dashboard_official_client_session
module Official_client_probe = Server_dashboard_official_client_probe
module Keeper_api_types = Server_dashboard_http_keeper_api_types

let config_cache_ttl_s = Server_dashboard_http_core_cache.config_cache_ttl_s
let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let live_cache_ttl_s = Server_dashboard_http_core_cache.live_cache_ttl_s
let exact_lane_run_permission = Masc_domain.CanAdmin
let runtime_probe_read_permission = Masc_domain.CanReadState

(* The panel draws a table; a page an operator can actually scan is ~50 rows.
   The ceiling exists so a caller cannot ask for the whole store back and
   reinstate the 246 MB response this paging replaced. *)
let exact_lane_run_page_default = 50
let exact_lane_run_page_max = 200
let exact_lane_run_detail_prefix = "/api/v1/dashboard/exact-lane-runs/"

let dashboard_actor_cache_segment state req =
  dashboard_actor_for_request
    ~base_path:(Mcp_server.workspace_config state).base_path
    req
;;

let respond_goal_tree_workspace_refusal req reqd error =
  let json, status = Server_auth.read_workspace_precondition_error_response error in
  (* This bounded refusal must not queue behind a busy read pool. *)
  let body, headers = Http_response_payload.compress_body
    ~accept_encoding:(Http_response_payload.accept_encoding_fields
      (Httpun.Headers.get_multi req.Httpun.Request.headers "accept-encoding"))
    (Yojson.Safe.to_string json) in
  let admitted_name = fst Workspace.read_precondition_admission_header in
  let other_headers = Http.Response.scoped_headers () |> List.filter (fun (name, _) ->
    not (String.equal (String.lowercase_ascii name) admitted_name)) in
  Http.Response.with_scoped_headers other_headers (fun () ->
    Http.Response.bytes ~status ~headers:(headers @ public_read_cors_headers req)
      ~content_type:"application/json; charset=utf-8" body reqd)
;;

let fusion_run_list_response ~registry =
  Server_dashboard_fusion_run_projection.list_response
    ~generated_at:(Masc_domain.now_iso ())
    ~registry
;;

let fusion_run_detail_response ~registry ~path =
  Server_dashboard_fusion_run_projection.detail_response
    ~generated_at:(Masc_domain.now_iso ())
    ~registry
    ~path
;;

let respond_dashboard_ok ?request reqd =
  Http.Response.json_value ?request ~compress:true
    (`Assoc [ ("ok", `Bool true) ])
    reqd

let respond_official_client_session_result request reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request json reqd
  | Error
      ({ Official_client_session.kind; code; message } :
        Official_client_session.error) ->
    let status =
      match kind with
      | Bad_request -> `Bad_request
      | Conflict -> `Conflict
      | Service_unavailable -> `Service_unavailable
    in
    Http.Response.json_value
      ~status
      ~request
      (`Assoc
        [ "schema", `String "masc.dashboard.official-client-session.error.v1"
        ; "ok", `Bool false
        ; "error_code", `String code
        ; "error", `String message
        ])
      reqd

let respond_official_client_probe_result request reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request json reqd
  | Error
      ({ Official_client_probe.kind; code; message } : Official_client_probe.error) ->
    let status =
      match kind with
      | Bad_request -> `Bad_request
      | Not_found -> `Not_found
      | Service_unavailable -> `Service_unavailable
    in
    Http.Response.json_value
      ~status
      ~request
      (`Assoc
        [ "schema", `String "masc.dashboard.official-client-probe.error.v1"
        ; "ok", `Bool false
        ; "error_code", `String code
        ; "error", `String message
        ])
      reqd

let execute_output_heartbeat_s = 15.0

let execute_output_keeper ~prefix path =
  match Server_utils.extract_path_param ~prefix path with
  | None -> None
  | Some encoded ->
    let keeper = Uri.pct_decode encoded |> String.trim in
    if String.equal keeper "" then None else Some keeper
;;

let handle_execute_output_stream ~sw ~clock _state req inner_reqd =
       let path = Http.Request.path req in
       let keeper =
         match
           execute_output_keeper
             ~prefix:"/api/dashboard/execute-output/"
             path
         with
         | Some value -> Some value
         | None ->
           execute_output_keeper
             ~prefix:"/api/v1/dashboard/execute-output/"
             path
       in
       match keeper with
       | None ->
         Keeper_api_types.respond_error
           ~status:`Bad_request
           ~request:req
           inner_reqd
           "keeper path parameter is required"
       | Some keeper_name ->
         let headers =
           Httpun.Headers.of_list
             ([ "content-type", "text/event-stream"
              ; "cache-control", "private, no-store"
              (* Httpun delimits this streaming body by closing the connection. *)
              ; "connection", "close"
              ; "x-accel-buffering", "no"
              ]
              @ Http.Response.scoped_headers ()
              @ public_read_cors_headers req)
         in
         let response =
           Server_sse_response.respond ~clock
             ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
             inner_reqd (Httpun.Response.create ~headers `OK)
         in
         let close_stream () = Server_sse_response.close response in
         let write_string data =
           match Server_sse_response.send response data with
           | Server_sse_response.Written -> true
           | Closed | Stalled -> false
         in
         let write_json json =
           write_string (Dashboard_execute_output.sse_frame json)
         in
         let subscriber = Dashboard_execute_output.subscribe ~keeper_name in
         let cleanup () =
           Option.iter Dashboard_execute_output.unsubscribe subscriber;
           close_stream ()
         in
         (* The handler must return to the HTTP driver before awaiting a
            flush. The subscriber is installed first so that events arriving
            while the first frame is in flight remain observable. *)
         (try
            Eio.Fiber.fork ~sw (fun () ->
              Eio.Switch.run (fun stream_sw ->
                Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
                  [ cleanup ];
                try
                  match subscriber with
                  | None ->
                    ignore (write_json (Dashboard_execute_output.event_json ~keeper_name))
                  | Some subscriber ->
                    let wrote_initial =
                      write_string
                        (Printf.sprintf "retry: %d\n\n" sse_dashboard_retry_backoff_ms)
                      && write_json (Dashboard_execute_output.initial_event_json subscriber)
                    in
                    if wrote_initial then (
                      let rec loop () =
                        if not (Server_sse_response.is_closed response)
                        then (
                          (* An event taken as the heartbeat came due is that
                             event: it has left the subscriber, and a heartbeat
                             written in its place would drop it from the stream. *)
                          match
                            Watched_work.run
                              ~watcher:(fun () ->
                                Eio.Time.sleep clock execute_output_heartbeat_s;
                                Error `Timeout)
                              (fun () -> Ok (Dashboard_execute_output.take_event subscriber))
                          with
                          | Ok event ->
                            if
                              write_json
                                (Dashboard_execute_output.stream_event_json event)
                            then loop ()
                          | Error `Timeout ->
                            if write_string ": heartbeat\n\n" then loop ())
                      in
                      loop ())
                with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Dashboard.warn
                     "execute output stream loop failed: %s"
                     (Printexc.to_string exn)))
          with exn ->
            cleanup ();
            raise exn)

let runtime_editor_protocol_json (protocol : Runtime_toml.editor_protocol) =
  let transport =
    match protocol.transport with
    | Runtime_toml.Endpoint -> "endpoint"
    | Runtime_toml.Command -> "command"
  in
  let semantics =
    match protocol.semantics with
    | Runtime_toml.Http_provider -> "http_provider"
    | Runtime_toml.Official_client -> "official_client"
  in
  let credential_policy =
    match protocol.credential_policy with
    | Runtime_toml.Credentials_optional -> "optional"
    | Runtime_toml.Credentials_forbidden -> "forbidden"
    | Runtime_toml.Credentials_file_required -> "file_required"
  in
  `Assoc
    [ "protocol", `String protocol.protocol
    ; "transport", `String transport
    ; "semantics", `String semantics
    ; "credential_policy", `String credential_policy
    ; "requires_non_interactive", `Bool protocol.requires_non_interactive
    ; "provider_fields", Json_util.json_string_list protocol.provider_fields
    ; ( "required_provider_fields"
      , Json_util.json_string_list protocol.required_provider_fields )
    ]
;;

let keeper_setting_payload keeper_document =
  match keeper_document with
  | Error detail ->
    ( `Assoc
        [ "valid", `Bool false
        ; "parse_error", `String detail
        ; "issues", `List []
        ]
    , `List []
    , `Assoc
        [ "status", `String "invalid"
        ; "configured_count", `Int 0
        ; "requires_restart", `Bool false
        ; "pending_keys", `List []
        ; "applied_keys", `List []
        ; "preempted_keys", `List []
        ; "applied_at", `Null
        ] )
  | Ok doc ->
    ( Keeper_runtime_config.validation_report_to_yojson
        (Keeper_runtime_config.validate_doc doc)
    , Keeper_runtime_config.settings_projection_to_yojson doc
    , Keeper_runtime_config.overlay_application_to_yojson doc )
;;

let skill_application_json = function
  | Error _ -> `Assoc [ "state", `String "invalid_workspace" ]
  | Ok (Server_skill_snapshot_runtime.Superseded { commit_order; applied_order }) ->
    `Assoc
      [ "state", `String "superseded"
      ; ( "commit_order"
        , `String (Runtime.config_commit_order_to_string commit_order) )
      ; ( "applied_order"
        , `String (Runtime.config_commit_order_to_string applied_order) )
      ]
  | Ok (Server_skill_snapshot_runtime.Applied { input_source_revision; publication }) ->
    let input_revision =
      `String (Runtime.config_source_revision_to_string input_source_revision)
    in
    let ready state snapshot =
      `Assoc
        [ "state", `String state
        ; "input_source_revision", input_revision
        ; ( "snapshot_revision"
          , `String
              (Skill_catalog_snapshot.snapshot_revision snapshot
               |> Skill_catalog_snapshot.snapshot_revision_to_string) )
        ; ( "catalog_revision"
          , `String
              (Skill_catalog_snapshot.catalog_revision snapshot
               |> Skill_catalog_snapshot.catalog_revision_to_string) )
        ; ( "config_state"
          , `String
              (Skill_catalog_snapshot.config_state snapshot
               |> Skill_catalog_snapshot.config_state_to_string) )
        ]
    in
    (match publication with
     | Workspace_retired ->
       `Assoc
         [ "state", `String "workspace_retired"
         ; "input_source_revision", input_revision
         ]
     | Published snapshot -> ready "published" snapshot
     | Unchanged snapshot -> ready "unchanged" snapshot)
;;

let runtime_config_application_json
      ?skill_application
      ?exact_output_registry
      ~operation
      ~routing_applied_at
      overlay
  =
  `Assoc
    ([ "operation", `String operation
    ; ( "routing"
      , `Assoc
          [ "status", `String (if Option.is_some routing_applied_at then "applied" else "active")
          ; "requires_restart", `Bool false
          ; ( "applied_at"
            , match routing_applied_at with
              | Some value -> `String value
              | None -> `Null )
          ] )
    ; "keeper_overlay", overlay
    ]
     @ (match skill_application with
        | None -> []
        | Some application -> [ "skills", skill_application_json application ])
     @ match exact_output_registry with
       | None -> []
       | Some outcome ->
         [ "exact_output_registry", Runtime.exact_output_registry_application_to_yojson outcome ])
;;

let runtime_config_raw_json
      ?commit
      ?skill_application
      ~source_revision
      ~path
      ~source_text
      ~operation
      ~routing_applied_at
      ()
  =
  (* Runtime home expansion, overlay/environment observations and account
     files make this an IO preparation job, not a pure CPU decoder. The auth
     check and response writer remain on the HTTP fiber. *)
  Eio_guard.with_named_switch "runtime-config-response" (fun () ->
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      let source = Server_runtime_config_source.prepare source_text in
      Log.Dashboard.debug "runtime_config_response operation=%s syntax_inputs=%s" operation
        (match source.syntax_inputs with
         | Server_runtime_config_source.Shared_input -> "shared"
         | Reader_specific_inputs -> "reader_specific");
      let validation, keeper_settings, overlay = keeper_setting_payload source.keeper in
      let source_revision_text = Runtime.config_source_revision_to_string source_revision in
      let model_bindings =
        Result.bind
          (Result.map_error (fun errors -> String.concat "; "
             (List.map (fun (error : Runtime_toml.parse_error) -> error.path ^ ": " ^ error.message) errors)) source.runtime)
          Runtime_config_models.of_config
      in
      (* Models identifies the accounts in this exact source observation, which
         may differ from the providers currently loaded by the runtime. *)
      let account_groups, account_emails =
        match source.runtime with
        | Ok config -> Runtime_wizard_inventory.account_groups_json config,
            Runtime_account_email.inventory_json config
        | Error _ -> `Null, `Null
      in
      `Assoc
        ([ ("ok", `Bool true)
        ; ( "source_revision"
          , `String source_revision_text )
        ; ("path", `String path)
        ; ("file_name", `String Config_dir_resolver.runtime_toml_filename)
        ; ("source_text", `String source.source_text)
        ; ("account_groups", account_groups)
        ; ("account_emails", account_emails)
        ; ("model_bindings", Runtime_config_models.to_json ~path
            ~source_revision:source_revision_text model_bindings)
        ; ( "application"
          , runtime_config_application_json
              ?skill_application
              ?exact_output_registry:
                (Option.map
                   (fun (receipt : Runtime.config_commit_receipt) ->
                      receipt.exact_output_registry)
                   commit)
              ~operation
              ~routing_applied_at
              overlay )
        ; "validation", validation
        ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
        ; "keeper_settings", keeper_settings
        ; ( "provider_protocols"
          , `List (List.map runtime_editor_protocol_json Runtime_toml.editor_protocols) )
        ; ( "reserved_provider_ids"
          , `List (List.map (fun id -> `String id) Runtime_toml.reserved_provider_ids) )
        ]
         @ match commit with
           | None -> []
           | Some receipt ->
             [ "state", `String "committed"
             ; "commit", Runtime.config_commit_receipt_to_yojson receipt
             ])))

let runtime_config_line_count = Server_skill_write_audit.line_count

(* RFC fusion-seat-routes §2.5 — the typed fusion write. The client sends the
   revision it read with the settings; the edit re-checks it inside the config
   lock, so a write that landed in between is refused rather than overwritten. *)
let parse_fusion_edit_body body_str =
  Result.bind (Server_json_object_body.fields body_str) (fun fields ->
    (match
       List.find_opt
         (fun (key, _) -> not (List.mem key [ "expected_revision"; "operation" ]))
         fields
     with
     | Some (key, _) -> Error (Printf.sprintf "unknown key %S" key)
     | None ->
       (match List.assoc_opt "expected_revision" fields, List.assoc_opt "operation" fields with
        | Some (`String revision), Some operation ->
          Result.map
            (fun operation -> revision, operation)
            (Fusion_config_edit.operation_of_yojson operation)
        | Some (`String _), None -> Error "operation required"
        | Some _, _ -> Error "expected_revision must be a string"
        | None, _ -> Error "expected_revision required")))
;;

let runtime_config_source_text fields =
  match List.filter (fun (key, _) -> String.equal key "source_text") fields with
  | [_, `String source_text] -> Ok source_text
  | [_] -> Error "source_text must be a string"
  | [] -> Error "source_text required"
  | _ -> Error "source_text must occur exactly once"

let parse_runtime_config_raw_body body_str =
  Result.bind (Server_json_object_body.fields body_str) runtime_config_source_text

let parse_runtime_config_raw_save_body body_str =
  let open Result.Syntax in
  let* fields = Server_json_object_body.fields body_str in
  let* source_text = runtime_config_source_text fields in
  (* Require one revision: duplicate revision fields cannot identify an editor base. *)
  let* revision = match List.filter (fun (key, _) -> String.equal key "expected_source_revision") fields with
   | [_, `String revision] when String_util.is_lowercase_sha256_hex revision -> Ok revision
   | [] -> Error "expected_source_revision required"
   | [_] -> Error "expected_source_revision must be lowercase SHA-256 hex"
   | _ -> Error "expected_source_revision must occur exactly once" in
  let* path = match List.filter (fun (key, _) -> String.equal key "expected_source_path") fields with
   | [_, `String path] when path <> "" && not (String.contains path '\000') -> Ok path
   | [] -> Error "expected_source_path required"
   | [_] -> Error "expected_source_path must be a nonempty path without NUL"
   | _ -> Error "expected_source_path must occur exactly once" in
  Ok (source_text, revision, path)
;;

let runtime_config_path_error_status message =
  if String.equal message Runtime.runtime_config_path_missing_message
  then `Not_found
  else `Internal_server_error

type runtime_config_write_operation =
  | Runtime_config_raw_save
  | Runtime_config_routing of Runtime_request.runtime_route_lane * string option
  | Runtime_config_routing_list of Runtime_request.runtime_route_lane * string list
  | Runtime_config_lane_created of string * string list
  | Runtime_config_lane_removed of string
  | Runtime_config_lane_renamed of string * string
  | Runtime_config_exact_slot_appended of Runtime.exact_lane * string
  | Runtime_config_exact_slot_dropped of Runtime.exact_lane * string
  | Runtime_config_exact_slot_replaced of Runtime.exact_lane * string * string
  | Runtime_config_exact_slot_moved of
      Runtime.exact_lane * string * Runtime.exact_slot_move
  | Runtime_config_assignment of string * string option
  | Runtime_config_fusion of string
  | Runtime_config_account_removal of string
  | Runtime_config_tui_preference of Tui_preference.change

let runtime_config_write_operation_details =
  let open Runtime_request in
  function
  | Runtime_config_raw_save -> [ ("operation", `String "raw_save") ]
  | Runtime_config_routing (lane, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string lane))
    ; ( "cleared"
      , `Bool
          (match runtime_id with
           | None -> true
           | Some _ -> false) )
    ]
    @
    (match runtime_id with
     | None -> []
     | Some id -> [ ("runtime_id", `String id) ])

  | Runtime_config_routing_list (lane, runtime_ids) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string lane))
    ; ("cleared", `Bool (List.length runtime_ids = 0))
    ; "runtime_ids", `List (List.map (fun id -> `String id) runtime_ids)
    ]
  | Runtime_config_lane_created (lane_id, runtime_ids) ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "create")
    ; "runtime_ids", `List (List.map (fun id -> `String id) runtime_ids)
    ]
  | Runtime_config_lane_removed lane_id ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "remove")
    ]
  | Runtime_config_lane_renamed (lane_id, new_lane_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String lane_id)
    ; ("action", `String "rename")
    ; ("to", `String new_lane_id)
    ]
  | Runtime_config_exact_slot_appended (exact, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "append")
    ; ("runtime_id", `String runtime_id)
    ]
  | Runtime_config_exact_slot_dropped (exact, runtime_id) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "drop")
    ; ("runtime_id", `String runtime_id)
    ]
  | Runtime_config_exact_slot_moved (exact, runtime_id, move) ->
    [ ("operation", `String "routing")
    ; ("lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact)))
    ; ("action", `String "move")
    ; ("runtime_id", `String runtime_id)
    ; ( "direction"
      , `String
          (match move with
           | Runtime.Move_slot_up -> "up"
           | Runtime.Move_slot_down -> "down"
           | Runtime.Move_slot_first -> "first") )
    ]
  | Runtime_config_exact_slot_replaced (exact, runtime_id, replacement) ->
    [ "operation", `String "routing"
    ; "lane", `String (runtime_route_lane_to_string (Runtime_exact_lane exact))
    ; "action", `String "replace"
    ; "runtime_id", `String runtime_id
    ; "replacement_runtime_id", `String replacement ]
  | Runtime_config_assignment (keeper_name, runtime_id) ->
    [ ("operation", `String "assignment")
    ; ("keeper_name", `String keeper_name)
    ; ( "cleared"
      , `Bool
          (match runtime_id with
           | None -> true
           | Some _ -> false) )
    ]
    @
    (match runtime_id with
     | None -> []
     | Some id -> [ ("runtime_id", `String id) ])
  | Runtime_config_fusion edit ->
    [ ("operation", `String "fusion"); ("edit", `String edit) ]
  | Runtime_config_account_removal integration_id ->
    [ ("operation", `String "account_removal"); ("integration_id", `String integration_id) ]
  | Runtime_config_tui_preference change ->
    [ ("operation", `String "tui_preference"); ("change", Tui_preference.change_to_yojson change) ]

let runtime_config_write_operation_label = function
  | Runtime_config_raw_save -> "raw_save"
  | Runtime_config_routing _ | Runtime_config_routing_list _
  | Runtime_config_lane_created _ | Runtime_config_lane_removed _
  | Runtime_config_lane_renamed _
  | Runtime_config_exact_slot_appended _ | Runtime_config_exact_slot_dropped _
  | Runtime_config_exact_slot_moved _ | Runtime_config_exact_slot_replaced _ -> "routing"
  | Runtime_config_assignment _ -> "assignment"
  | Runtime_config_fusion _ -> "fusion"
  | Runtime_config_account_removal _ -> "account_removal"
  | Runtime_config_tui_preference _ -> "tui_preference"
;;

(* 409 while the file is not the one the preview read, or no longer allows
   the removal it listed; 503 when it cannot be read. *)
let account_removal_status : Runtime_account_removal_setup.error -> Httpun.Status.t = function
  | Runtime_account_removal_setup.Invalid_request
  | Runtime_account_removal_setup.Save_rejected _ -> `Bad_request
  | Runtime_account_removal_setup.Configuration_unavailable _ -> `Service_unavailable
  | Runtime_account_removal_setup.Configuration_changed
  | Runtime_account_removal_setup.Refused _ -> `Conflict
;;

let keeper_validation_error_message report =
  match
    List.find_opt
      (fun issue -> issue.Keeper_runtime_config.severity = Keeper_runtime_config.Error)
      report.Keeper_runtime_config.issues
  with
  | Some issue -> Printf.sprintf "%s: %s" issue.key issue.detail
  | None -> "Keeper runtime setting validation failed"
;;

let respond_keeper_validation_error ~request reqd report =
  Http.Response.json_value
    ~status:`Bad_request
    ~request
    (`Assoc
      [ "ok", `Bool false
      ; "error", `String (keeper_validation_error_message report)
      ; "validation", Keeper_runtime_config.validation_report_to_yojson report
      ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
      ])
    reqd
;;

let audit_runtime_config_write
      state
      agent_name
      ?path
      ?receipt
      ?skill_application
      ~operation
      ~text
      ~outcome
      ()
  =
  try
    Audit_log.log_action
      (Mcp_server.workspace_config state)
      ~agent_id:agent_name
      ~action:Audit_log.RuntimeConfigWrite
      ~details:
        (`Assoc
           ((match path with
             | Some p -> [ ("path", `String p) ]
             | None -> [])
            @ runtime_config_write_operation_details operation
            @ [ ("bytes", `Int (String.length text))
              ; ("lines", `Int (runtime_config_line_count text))
              ]
            @ (match receipt with
               | None -> []
               | Some (commit : Runtime.config_commit_receipt) ->
                 [ "commit", Runtime.config_commit_receipt_to_yojson commit
                 ; ( "exact_output_registry"
                   , Runtime.exact_output_registry_application_to_yojson commit.exact_output_registry )
                 ])
            @ (match skill_application with
               | None -> []
               | Some application ->
                 [ "skills", skill_application_json application ])))
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.warn
      "runtime.toml audit log failed: %s"
      (Printexc.to_string exn)

let respond_runtime_config_commit
      state
      agent_name
      ~operation
      ~receipt
      request
      reqd
  =
  let observation = receipt.Runtime.observation in
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  let response_json =
    Eio.Cancel.protect (fun () ->
      let skill_application =
        Server_skill_snapshot_runtime.apply_commit ~base_path receipt
      in
      audit_runtime_config_write state agent_name ~path:observation.path
        ~receipt ~skill_application ~operation ~text:observation.source_text
        ~outcome:Audit_log.Success ();
      runtime_config_raw_json
        ~commit:receipt
        ~skill_application
        ~source_revision:observation.source_revision
        ~path:observation.path
        ~source_text:observation.source_text
        ~operation:(runtime_config_write_operation_label operation)
        ~routing_applied_at:(Some (Masc_domain.now_iso ()))
        ())
  in
  Http.Response.json_value ~compress:true ~request
    response_json
    reqd

let handle_runtime_config_raw_post state agent_name req reqd body_str =
  match parse_runtime_config_raw_save_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (source_text, expected_source_revision, expected_source_path) ->
    (* Audit metadata excludes the source, which can contain provider secrets. *)
    (match Keeper_runtime_config.validate_source_text source_text with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:Runtime_config_raw_save ~text:source_text
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
         ("runtime config parse failed: " ^ msg)
     | Ok report when not (Keeper_runtime_config.validation_report_is_valid report) ->
       let detail = keeper_validation_error_message report in
       audit_runtime_config_write state agent_name
         ~operation:Runtime_config_raw_save ~text:source_text
         ~outcome:(Audit_log.Failure detail) ();
       respond_keeper_validation_error ~request:req reqd report
     | Ok _ ->
       (match Runtime.save_config_text_if_current ~expected_source_path ~expected_source_revision source_text with
        | Error (Runtime.Config_edit_failed msg) ->
          audit_runtime_config_write state agent_name
            ~operation:Runtime_config_raw_save ~text:source_text
            ~outcome:(Audit_log.Failure msg) ();
          Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
        | Error (Runtime.Config_source_conflict current) ->
          Http.Response.json_value ~status:`Conflict ~request:req
            (`Assoc
              [ "error", `String "runtime configuration changed; reload before saving"
              ; "code", `String "revision_conflict"
              ; "current", `Assoc
                  [ "source_path", `String current.path
                  ; "source_text", `String current.source_text
                  ; "source_revision", `String
                      (Runtime.config_source_revision_to_string current.source_revision)
                  ]
              ]) reqd
        | Ok receipt ->
          respond_runtime_config_commit state agent_name
            ~operation:Runtime_config_raw_save ~receipt req reqd))
;;

let handle_runtime_assignment_post_with ~set_assignment state agent_name req reqd
    body_str =
  match Runtime_request.parse_runtime_assignment_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (keeper_name, runtime_id, expected) ->
    (match
       set_assignment
         ~runtime_config_path:
           (Config_dir_resolver.runtime_toml_path_for_base_path
              ~base_path:
                (Mcp_server.workspace_config state).Workspace.base_path)
         ~keeper_name ~runtime_id ~expected ()
     with
     | Error (Runtime.Assignment_io_error msg) ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
         ~text:body_str ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Error (Runtime.Assignment_revision_conflict observed) ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
         ~text:body_str
         ~outcome:(Audit_log.Failure "runtime assignment revision conflict")
         ();
       Http.Response.json_value ~status:`Conflict ~request:req
         (`Assoc
            [ "ok", `Bool false
            ; ( "error"
              , `Assoc
                  [ "code", `String "runtime_assignment_revision_conflict"
                  ; "expected", Runtime.keeper_assignment_revision_to_yojson expected
                  ; "observed", Runtime.keeper_assignment_revision_to_yojson observed
                  ] )
            ])
         reqd
     | Ok locked ->
       (match locked.Runtime.value with
        | Runtime.Assignment_unchanged revision ->
          audit_runtime_config_write state agent_name
            ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
            ~text:body_str ~outcome:Audit_log.Success ();
          Http.Response.json_value ~request:req
            (`Assoc
               [ "ok", `Bool true
               ; "applied", `Bool false
               ; "assignment_revision", Runtime.keeper_assignment_revision_to_yojson revision
               ; ( "warnings"
                 , `List
                     (List.map Runtime.config_lock_warning_to_yojson
                        locked.warnings) )
               ])
            reqd
        | Runtime.Assignment_committed { receipt; _ } ->
          respond_runtime_config_commit state agent_name
            ~operation:(Runtime_config_assignment (keeper_name, runtime_id))
            ~receipt req reqd))

let handle_runtime_assignment_post state agent_name req reqd body_str =
  handle_runtime_assignment_post_with
    ~set_assignment:(fun ~runtime_config_path ~keeper_name ~runtime_id
                          ~expected () ->
      Runtime.set_keeper_assignment_if_revision ~runtime_config_path
        ~keeper_name ~runtime_id ~expected ())
    state agent_name req reqd body_str

(* GET /api/v1/tui/preferences, after authentication: the [tui] settings of
   the runtime.toml this server writes. *)
let handle_tui_preferences_get state req reqd =
  let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
  Http.Response.json_value ~request:req
    (Tui_preference.settings_to_yojson
       (Tui_preference.read_settings
          ~path:(Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)))
    reqd

(* POST /api/v1/tui/preferences, after authentication: one change to the
   [tui] table of runtime.toml, parsed at the door (RFC-0482 §3.1). The edit
   goes through Runtime's config write lock and commit, so the commit
   announces runtime_config_changed like every other save. A change that
   leaves the text as it is -- a second visit to the same chat, a hint
   already retired -- writes, audits and announces nothing. The [tui] keys
   are not read by the Skill catalog, so, as when the terminal wrote them
   itself, the commit does not republish it. The answer carries the commit
   receipt and not the file: the reader already holds its choice. *)
let handle_tui_preference_post state agent_name req reqd body_str =
  match
    match Yojson.Safe.from_string body_str with
    | json -> Tui_preference.change_of_yojson json
    | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  with
  | Error msg -> Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok change ->
    let operation = Runtime_config_tui_preference change in
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    (match
       Runtime.edit_config_text_if_changed
         ~runtime_config_path:(Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
         (Tui_preference.edit change)
     with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok (Runtime.Config_text_unchanged { observation; lock_warnings }) ->
       Http.Response.json_value ~request:req
         (`Assoc
            [ "ok", `Bool true
            ; "state", `String "unchanged"
            ; "change", Tui_preference.change_to_yojson change
            ; ( "source_revision"
              , `String (Runtime.config_source_revision_to_string observation.source_revision) )
            ; "warnings", `List (List.map Runtime.config_lock_warning_to_yojson lock_warnings)
            ])
         reqd
     | Ok (Runtime.Config_text_committed receipt) ->
       let observation = receipt.Runtime.observation in
       Eio.Cancel.protect (fun () ->
         audit_runtime_config_write state agent_name ~path:observation.path ~receipt ~operation
           ~text:observation.source_text ~outcome:Audit_log.Success ());
       Http.Response.json_value ~request:req
         (`Assoc
            [ "ok", `Bool true
            ; "state", `String "committed"
            ; "change", Tui_preference.change_to_yojson change
            ; "commit", Runtime.config_commit_receipt_to_yojson receipt
            ])
         reqd)

(* POST /api/v1/runtime/config/routing, after authentication: one routing
   body, parsed to a variant, answered by the Runtime writer it names. *)
let handle_runtime_routing_post state agent_name req reqd body_str =
  let open Runtime_request in
  match parse_runtime_route_body body_str with
  | Error msg ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
  | Ok (Runtime_route_runtime_id (Runtime_default, Some runtime_id)) ->
    (match Runtime.set_runtime_default ~runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_default, None)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "default runtime_id required"
  | Ok (Runtime_route_runtime_id (Runtime_media_failover, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "media_failover runtime_ids required"
  | Ok (Runtime_route_runtime_ids (Runtime_media_failover, runtime_ids)) ->
    (match Runtime.set_runtime_media_failover ~runtime_ids () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_named_lane lane_id, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      (Printf.sprintf "%s runtime_ids required" lane_id)
  | Ok (Runtime_route_runtime_ids (Runtime_named_lane lane_id, runtime_ids))
    ->
    (match Runtime.set_runtime_lane_candidates ~lane_id ~runtime_ids () with
     | Error error ->
       let msg = Runtime.lane_set_error_to_string error in
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_named_lane lane_id, runtime_ids))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_named_lane lane_id, runtime_ids))
         ~receipt req reqd)
  | Ok (Runtime_route_named_lane_set_if_revision (lane_id, runtime_ids, revision)) ->
    let operation = Runtime_config_routing_list (Runtime_named_lane lane_id, runtime_ids) in
    (match Runtime.set_runtime_lane_candidates ~lane_id ~runtime_ids
             ~expected_source_revision:revision () with
     | Error error ->
       let msg = Runtime.lane_set_error_to_string error in
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error
         ~status:(match error with
                  | Runtime.Lane_set_revision_conflict _ -> `Conflict
                  | Runtime.Lane_set_invalid _ -> `Bad_request)
         ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_runtime_id (Runtime_exact_lane _, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      "exact-output lane runtime_ids required"
  | Ok (Runtime_route_runtime_ids (Runtime_exact_lane exact, slots))
    ->
    (match Runtime.set_exact_output_lane_slots ~lane:exact ~slots () with
     | Error msg ->
       audit_runtime_config_write state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_exact_lane exact, slots))
         ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name
         ~operation:
           (Runtime_config_routing_list
              (Runtime_exact_lane exact, slots))
         ~receipt req reqd)
  | Ok (Runtime_route_runtime_ids (lane, _)) ->
    Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd
      (Printf.sprintf
         "%s runtime_id required"
         (runtime_route_lane_to_string lane))
  | Ok (Runtime_route_lane_created (lane_id, runtime_ids)) ->
    let operation = Runtime_config_lane_created (lane_id, runtime_ids) in
    (match Runtime.create_runtime_lane ~lane_id ~runtime_ids () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_lane_removed lane_id) ->
    let operation = Runtime_config_lane_removed lane_id in
    (match Runtime.remove_runtime_lane ~lane_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_lane_renamed (lane_id, new_lane_id)) ->
    let operation = Runtime_config_lane_renamed (lane_id, new_lane_id) in
    (match Runtime.rename_runtime_lane ~lane_id ~new_lane_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_appended (exact, runtime_id)) ->
    let operation = Runtime_config_exact_slot_appended (exact, runtime_id) in
    (match Runtime.append_exact_output_lane_slot ~lane:exact ~slot:runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_dropped (exact, runtime_id)) ->
    let operation = Runtime_config_exact_slot_dropped (exact, runtime_id) in
    (match Runtime.drop_exact_output_lane_slot ~lane:exact ~slot:runtime_id () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_moved (exact, runtime_id, move)) ->
    let operation = Runtime_config_exact_slot_moved (exact, runtime_id, move) in
    (match
       Runtime.move_exact_output_lane_slot ~lane:exact ~slot:runtime_id ~move ()
     with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)
  | Ok (Runtime_route_exact_slot_replaced (exact, runtime_id, replacement)) ->
    let operation = Runtime_config_exact_slot_replaced (exact, runtime_id, replacement) in
    (match Runtime.replace_exact_output_lane_slot ~lane:exact ~slot:runtime_id ~replacement () with
     | Error msg ->
       audit_runtime_config_write state agent_name ~operation ~text:body_str
         ~outcome:(Audit_log.Failure msg) ();
       Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
     | Ok receipt ->
       respond_runtime_config_commit state agent_name ~operation ~receipt req reqd)

module For_testing = struct
  (* The request decoder is private to the server library; the named-lane
     array shape is a wire contract, so the parser test asserts it directly
     instead of through an HTTP round trip. *)
  let lane_string = Runtime_request.runtime_route_lane_to_string

  let parse_runtime_route_body body =
    let open Runtime_request in
    match Runtime_request.parse_runtime_route_body body with
    | Error detail -> Error detail
    | Ok (Runtime_route_runtime_id (lane, runtime_id)) ->
        Ok
          ( lane_string lane
          , "runtime_id"
          , match runtime_id with None -> [] | Some value -> [ value ] )
    | Ok (Runtime_route_runtime_ids (lane, runtime_ids)) ->
        Ok (lane_string lane, "runtime_ids", runtime_ids)
    | Ok (Runtime_route_named_lane_set_if_revision (lane_id, runtime_ids, _)) ->
        Ok (lane_id, "runtime_ids_if_revision", runtime_ids)
    | Ok (Runtime_route_lane_created (lane_id, runtime_ids)) ->
        Ok (lane_id, "create", runtime_ids)
    | Ok (Runtime_route_lane_removed lane_id) -> Ok (lane_id, "remove", [])
    | Ok (Runtime_route_lane_renamed (lane_id, new_lane_id)) ->
        Ok (lane_id, "rename", [ new_lane_id ])
    | Ok (Runtime_route_exact_slot_appended (exact, runtime_id)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "append", [ runtime_id ])
    | Ok (Runtime_route_exact_slot_dropped (exact, runtime_id)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "drop", [ runtime_id ])
    | Ok (Runtime_route_exact_slot_replaced (exact, runtime_id, replacement)) ->
        Ok (runtime_route_lane_to_string (Runtime_exact_lane exact), "replace", [runtime_id; replacement])
    | Ok (Runtime_route_exact_slot_moved (exact, runtime_id, move)) ->
        Ok
          ( runtime_route_lane_to_string (Runtime_exact_lane exact)
          , "move"
          , [ runtime_id
            ; (match move with
               | Runtime.Move_slot_up -> "up"
               | Runtime.Move_slot_down -> "down"
               | Runtime.Move_slot_first -> "first")
            ] )

  let exact_lane_run_permission = exact_lane_run_permission
  let runtime_probe_read_permission = runtime_probe_read_permission
  let handle_runtime_assignment_post = handle_runtime_assignment_post
  let handle_runtime_assignment_post_with = handle_runtime_assignment_post_with
  let handle_runtime_routing_post = handle_runtime_routing_post
  let handle_runtime_config_raw_post = handle_runtime_config_raw_post
  let handle_tui_preference_post = handle_tui_preference_post
  let handle_tui_preferences_get = handle_tui_preferences_get
  let fusion_run_detail_response = fusion_run_detail_response
  let fusion_run_list_response = fusion_run_list_response
end

(* The tool-quality read index could not be read; carries the index's detail
   across the cache compute boundary to the route below. *)
exception Tool_quality_log_unavailable of string

let add_routes ~sw ~clock router =
  router
  (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanBroadcast) "/api/v1/broadcast" (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           handle_broadcast state agent_name reqd body_str
         )
       )
  (* POST /broadcast - Alias for autocov compatibility *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanBroadcast) "/broadcast" (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           handle_broadcast state agent_name reqd body_str
         )
       )
  |> Server_route.prefix_get Server_route.Public_read
       "/api/dashboard/execute-output/"
       (handle_execute_output_stream ~sw ~clock)
  |> Server_route.prefix_get Server_route.Public_read
       "/api/v1/dashboard/execute-output/"
       (handle_execute_output_stream ~sw ~clock)

  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/shell" (fun state req reqd ->
         let light = Server_utils.bool_query_param req "light" ~default:false in
         let timing = Server_timing.create () in
         (* RFC-0138 Phase 3 Step 1: wait-free read via
            [Dashboard_snapshot.current ()] when the refresh fiber has
            published; falls back to [dashboard_shell_http_json] for
            light variant + first-request cold start. *)
         let json =
           Server_dashboard_snapshot_select.select_shell_json
             ?clock:state.Mcp_server.clock ~request:req
             ~timing ~light (Mcp_server.workspace_config state)
         in
         Http.Response.json_value ~compress:true ~request:req ~extra_headers:(Server_timing.extra_header timing) json reqd
       )
  (* RFC-0266 §7 Phase 4: read-only snapshot of the in-memory fusion run registry
     (in-progress + recently completed). The fusion panel fetches this on load and
     re-fetches on the [fusion_run_status] SSE event. Registry reads are O(runs)
     in-memory, so no Dashboard_cache layer; each run serializes through the shared
     Fusion_run_registry.run_to_yojson so the shape matches the SSE delta. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/fusion-runs" (fun _state req reqd ->
         let json =
           fusion_run_list_response ~registry:(Fusion_run_registry.global ())
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.prefix_get Server_route.Public_read
       Server_dashboard_fusion_run_projection.detail_prefix
       (fun _state req reqd ->
         let status, json =
           fusion_run_detail_response
             ~registry:(Fusion_run_registry.global ())
             ~path:(Http.Request.path req)
         in
         Http.Response.json_value
           ~status:(status :> Httpun.Status.t)
           ~compress:true
           ~request:req
           json
           reqd
       )
  (* RFC-0361 D4: read-only snapshot of the completion-authority review registry
     (in-progress + recently completed). Sibling of the fusion route above and
     shaped identically; each run serializes through the shared
     Verification_run_registry.run_to_yojson so the panel and any later SSE delta
     read one shape. Registry reads are O(runs) in-memory, so no Dashboard_cache
     layer. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/verification-runs" (fun _state req reqd ->
         let runs =
           Verification_run_registry.list_runs (Verification_run_registry.global ())
         in
         let json =
           `Assoc
             [ ("generated_at", `String (Masc_domain.now_iso ()))
             ; ("count", `Int (List.length runs))
             ; ("runs", `List (List.map Verification_run_registry.run_to_yojson runs))
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/goal-verification-runs" (fun _state req reqd ->
         let runs =
           Goal_verification_run_registry.list_runs
             (Goal_verification_run_registry.global ())
         in
         let json =
           `Assoc
             [ ("generated_at", `String (Masc_domain.now_iso ()))
             ; ("count", `Int (List.length runs))
             ; ( "runs"
               , `List
                   (List.map
                      Goal_verification_run_registry.row_to_yojson
                      runs) )
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  (* One bounded, read-only join of lane admission and retained observations.
     Unlike the paged run endpoint below this always names every standalone
     lanes, including configured lanes with no currently retained run. *)
  |> Server_route.get (Server_route.Token_permission exact_lane_run_permission) "/api/v1/dashboard/standalone-lanes" (fun _state _agent_name req reqd ->
            Http.Response.json_value
              ~compress:true
              ~request:req
              (Server_standalone_lane_projection.snapshot_json ())
              reqd)
  |> Server_route.get (Server_route.Token_permission exact_lane_run_permission) "/api/v1/lanes" (fun state _agent_name req reqd ->
            Server_lane_inventory.snapshot ~config:(Mcp_server.workspace_config state)
            |> Server_lane_inventory.to_json
            |> fun json -> Http.Response.json_value ~compress:true ~request:req json reqd)
  |> Server_route.get (Server_route.Token_permission exact_lane_run_permission) "/api/v1/dashboard/exact-lane-run-retention" (fun _state _agent_name req reqd ->
            Exact_lane_run_registry.startup_observation (Exact_lane_run_registry.global ())
            |> Server_exact_lane_retention_observation.to_json
            |> fun json -> Http.Response.json_value ~compress:true ~request:req json reqd)
  (* Paged, and without detail payloads. [lane=] and [run_kind=] filter BEFORE pagination so
     the Verifier's task/Goal review registries cannot be hidden behind a busy
     Librarian window. Serving every exact-output payload made this response
     246 MB for 5,908 runs; [exact-lane-runs/<run_id>] carries the exact prompt
     or retained review/tool evidence for the one run an operator opened. *)
  |> Server_route.get (Server_route.Token_permission exact_lane_run_permission) "/api/v1/dashboard/exact-lane-runs" (fun _state _agent_name req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:exact_lane_run_page_default
           |> Server_utils.clamp ~min_v:1 ~max_v:exact_lane_run_page_max
         in
         (* Both halves of the cursor or neither: a started_at without its
            run_id cannot break a tie, and silently paging from a half-given
            boundary would skip runs recorded in the same float second. *)
         let before =
           match
             ( Option.bind (Server_utils.query_param req "before_started_at") float_of_string_opt
             , Server_utils.query_param req "before_run_id" )
           with
           | Some started_at, Some run_id when not (String.equal (String.trim run_id) "") ->
             Ok (Some (started_at, run_id))
           | None, None -> Ok None
           | _ -> Error "before_started_at and before_run_id must be given together"
         in
         let lane =
           Option.bind
             (Server_utils.query_param req "lane" |> Option.map String.trim)
             (fun value -> if String.equal value "" then None else Some value)
         in
         let run_kind =
           match Server_utils.query_param req "run_kind" with
           | None -> Ok None
           | Some value ->
             Server_standalone_lane_projection.run_kind_of_string value
             |> Result.map Option.some
         in
         match before, run_kind with
         | Error message, _ | _, Error message ->
           Keeper_api_types.respond_error ~request:req reqd message
         | Ok before, Ok run_kind ->
           (match
              Server_standalone_lane_projection.recent_run_page_json
                ~limit ~before ~lane ~run_kind
            with
            | Error message ->
              Keeper_api_types.respond_error ~request:req reqd message
            | Ok json ->
              Http.Response.json_value ~compress:true ~request:req json reqd)
       )
  |> Server_route.prefix_get (Server_route.Token_permission exact_lane_run_permission) "/api/v1/dashboard/exact-lane-runs/" (fun _state _agent_name req reqd ->
         let run_id =
           String.length exact_lane_run_detail_prefix
           |> fun offset ->
           let target = Uri.path (Uri.of_string req.Httpun.Request.target) in
           if String.length target <= offset
           then ""
           else String.sub target offset (String.length target - offset)
         in
         let run_id = Uri.pct_decode run_id in
         if String.equal (String.trim run_id) ""
         then Keeper_api_types.respond_error ~request:req reqd "run_id is required"
         else (
           match Server_standalone_lane_projection.run_detail_json ~run_id with
           | Server_standalone_lane_projection.Detail_not_found ->
             Keeper_api_types.respond_error
               ~status:`Not_found
               ~request:req
               reqd
               ("no retained standalone lane run named " ^ run_id)
           | Server_standalone_lane_projection.Detail_ambiguous ->
             Keeper_api_types.respond_error
               ~status:`Internal_server_error
               ~request:req
               reqd
               ("multiple standalone run registries contain " ^ run_id)
           | Server_standalone_lane_projection.Detail_found json ->
             Http.Response.json_value
               ~compress:true
               ~request:req
               json
               reqd)
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/workspace" handle_dashboard_workspace
  (* Dev-only bearer for the dashboard UI, minted at the role named by
     [Server_routes_http_dashboard_dev_token.dashboard_dev_role]. Served
     exclusively when the server binds to loopback and strict-auth env
     overrides are disabled, so that a LAN deployment never hands out a
     credential over the wire. The token is canonicalized to the [dashboard]
     actor and persisted at [.masc/auth/dashboard.token]. *)
  |> Server_route.get (Server_route.Self_authenticated Route_access.Loopback_dev_token) "/api/v1/dashboard/dev-token" (fun request reqd ->
       if (not (http_auth_bind_is_loopback ()))
          || http_auth_strict_enabled () then
         Keeper_api_types.respond_error ~status:`Not_found ~request reqd
           "dev-token endpoint disabled (non-loopback bind or strict auth)"
       else
         with_public_read (fun state req reqd ->
           (* [with_public_read] checks a read precondition before this handler,
              but the active scope can change between that check and the token
              operation. Validate the same snapshot whose base path is used
              for issuance. Unbound bootstrap requests remain supported. *)
           let scope = Mcp_server.workspace_scope state in
           match Server_auth.validate_read_workspace_precondition ~config:scope.config req with
           | Error error -> respond_goal_tree_workspace_refusal req reqd error
           | Ok (Server_auth.Workspace_read_unbound | Server_auth.Workspace_read_matched) ->
             let raw_result =
               Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token_for_authority
                 ~request_authority:(Server_request_authority.current_exn ())
                 ~base_path:scope.config.base_path
             in
             begin
               match raw_result with
               | Ok token ->
                 Http.Response.json_value ~request:req
                   (`Assoc
                      [ "token", `String token.raw
                      ; "actor", `String token.actor
                      ; ( "role"
                        , `String (Masc_domain.agent_role_to_string token.role) )
                      ]) reqd
               | Error err ->
                 let status =
                   Server_routes_http_dashboard_dev_token.request_error_status err
                 in
                 let error_code =
                   Server_routes_http_dashboard_dev_token.request_error_code err
                 in
                 let message =
                   Server_routes_http_dashboard_dev_token.request_error_to_string err
                 in
                 Log.Auth.error
                   "dashboard dev-token denied code=%s detail=%s"
                   error_code
                   message;
                 Http.Response.json_value
                   ~status
                   ~request:req
                   (`Assoc
                      [ "error", `String message
                      ; "error_code", `String error_code
                      ])
                   reqd
             end) request reqd)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/inventory" (fun state _agent_name req reqd ->
           let base_path=(Mcp_server.workspace_config state).base_path in
           match Runtime_setup_batch.observe_inventory ~base_path with
           | Ok (revision,observation) ->
             (match Runtime_toml.parse_string observation.source_text with
              | Error _ -> Http.Response.json_value ~status:`Bad_request ~request:req
                  (`Assoc ["error", `String "Runtime configuration needs correction."]) reqd
              | Ok config -> Http.Response.json_value ~request:req
                  (match Runtime_wizard_inventory.to_json config with
                   | `Assoc fields -> `Assoc (("setup_revision",`String (Runtime_setup_batch.revision_to_string revision))
                       ::("source_revision",`String (Runtime.config_source_revision_to_string observation.source_revision))
                       ::("account_emails",Runtime_account_email.inventory_json config)::fields)
                   | value -> value) reqd)
           | Error _ -> Http.Response.json_value ~status:`Service_unavailable ~request:req
               (`Assoc ["error", `String "Runtime configuration is unavailable."]) reqd)
  (* The Overview reads this on every refresh, so it carries only the
     emails, for the providers the loaded runtimes run on: the same
     runtimes its Plan usage rows group. An email is personal data, so
     the route needs Admin like the setup inventory. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/account-emails" (fun _state _agent_name req reqd ->
           let _default_route, default, runtimes = Runtime.get_default_route_and_runtimes () in
           let providers =
             List.fold_left
               (fun providers (runtime : Runtime_instance.t) ->
                  if List.exists
                       (fun (known : Runtime_schema.provider) -> String.equal known.id runtime.provider.id)
                       providers
                  then providers
                  else providers @ [ runtime.provider ])
               []
               (Option.to_list default @ runtimes)
           in
           Http.Response.json_value ~request:req
             (`Assoc [ "account_emails", Runtime_account_email.providers_json providers ])
             reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/models" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match Eio_context.get_net_opt () with
               | None -> Error Server_runtime_setup_actions.Network_unavailable
               | Some net ->
                 (match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
                  | None -> Error Server_runtime_setup_actions.Invalid_request
                  | Some json -> Server_runtime_setup_actions.discover ~binary:Sys.executable_name ~sw ~net
                      ~base_path:(Mcp_server.workspace_config state).base_path json) in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/antigravity" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.import_account ~binary:Sys.executable_name
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login" (fun state actor req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             Server_setup_account_login.start ~actor
               ~base_path:(Mcp_server.workspace_config state).base_path ~body req reqd))
  |> Server_route.prefix_get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login/" (fun state actor req reqd ->
           Server_setup_account_login.status ~actor
             ~base_path:(Mcp_server.workspace_config state).base_path req reqd)
  |> Server_route.prefix_post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/login/" (fun state actor req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             Server_setup_account_login.control ~actor
               ~base_path:(Mcp_server.workspace_config state).base_path ~body req reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/select" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.select_account
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  (* What removing an account changes, answered with the revision it was
     read at; [/remove] commits it only while the file is still that
     revision. *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/removal" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let runtime_config_path =
               Config_dir_resolver.runtime_toml_path_for_base_path
                 ~base_path:(Mcp_server.workspace_config state).base_path
             in
             let result =
               match Yojson.Safe.from_string body with
               | json -> Runtime_account_removal_setup.preview ~runtime_config_path json
               | exception Yojson.Json_error _ -> Error Runtime_account_removal_setup.Invalid_request
             in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error ->
               Keeper_api_types.respond_error ~status:(account_removal_status error) ~request:req reqd
                 (Runtime_account_removal_setup.error_message error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/accounts/remove" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let runtime_config_path =
               Config_dir_resolver.runtime_toml_path_for_base_path
                 ~base_path:(Mcp_server.workspace_config state).base_path
             in
             let json =
               match Yojson.Safe.from_string body with
               | json -> Some json
               | exception Yojson.Json_error _ -> None
             in
             let integration_id =
               match json with
               | Some (`Assoc fields) ->
                 (match List.assoc_opt "integration_id" fields with
                  | Some (`String id) -> id
                  | Some _ | None -> "")
               | Some _ | None -> ""
             in
             let operation = Runtime_config_account_removal integration_id in
             let result =
               match json with
               | Some json -> Runtime_account_removal_setup.remove ~runtime_config_path json
               | None -> Error Runtime_account_removal_setup.Invalid_request
             in
             match result with
             | Ok receipt -> respond_runtime_config_commit state agent_name ~operation ~receipt req reqd
             | Error error ->
               audit_runtime_config_write state agent_name ~operation ~text:body
                 ~outcome:(Audit_log.Failure (Runtime_account_removal_setup.error_message error)) ();
               Keeper_api_types.respond_error ~status:(account_removal_status error) ~request:req reqd
                 (Runtime_account_removal_setup.error_message error)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/context" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match Eio_context.get_net_opt () with
               | None -> Error Server_runtime_setup_actions.Network_unavailable
               | Some net ->
                 (match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
                  | None -> Error Server_runtime_setup_actions.Invalid_request
                  | Some json -> Server_runtime_setup_actions.context ~binary:Sys.executable_name ~net
                      ~base_path:(Mcp_server.workspace_config state).base_path json) in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/connections" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let result = match (try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None) with
               | None -> Error Server_runtime_setup_actions.Invalid_request
               | Some json -> Server_runtime_setup_actions.save ~binary:Sys.executable_name
                   ~base_path:(Mcp_server.workspace_config state).base_path json in
             match result with
             | Ok json -> Http.Response.json_value ~request:req json reqd
             | Error error -> Http.Response.json_value ~status:(Server_runtime_setup_actions.status_of_error error) ~request:req
                 (`Assoc ["error",`String (Server_runtime_setup_actions.error_message error)]) reqd))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/credential" (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let reject message = Http.Response.json_value ~status:`Bad_request ~request:req
               (`Assoc ["ok", `Bool false; "error", `String message]) reqd in
             let decoded = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
             match decoded with
             | Some (`Assoc fields) when List.length fields = 3 ->
               (match List.assoc_opt "provider_id" fields, List.assoc_opt "secret" fields, List.assoc_opt "source_revision" fields, Runtime.config_path () with
                | Some (`String provider_id), Some (`String secret), Some (`String expected_source_revision), Some runtime_config_path ->
                  (match Runtime_setup_credentials.save ~secret () with
                   | Error error -> reject (Runtime_setup_credentials.error_message error)
                   | Ok pending -> Eio.Switch.run (fun sw ->
                     Eio.Switch.on_release sw (fun () -> Runtime_setup_credentials.remove_uncommitted pending);
                     match Runtime_setup_credentials.apply_to_provider ~runtime_config_path ~provider_id ~expected_source_revision pending with
                     | Error error -> reject (Runtime_setup_credentials.error_message error)
                     | Ok _ -> Http.Response.json_value ~request:req
                         (`Assoc ["ok", `Bool true; "configured", `Bool true;
                                  "verification", `String "not_run"]) reqd))
                | _ -> reject "Select a configured provider and enter its API key.")
             | _ -> reject "Expected a provider selection and API key."))
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/setup/status" (fun state _agent_name req reqd ->
           let config = Mcp_server.workspace_config state in
           let observed =
             Onboarding_status.inspect_loaded ~base_path:(Some config.base_path) in
           Http.Response.json_value ~request:req (Onboarding_status.to_json observed) reqd)
  |> Server_route.get (Server_route.Permission runtime_probe_read_permission) "/api/v1/dashboard/runtime-probe" (fun _state req reqd ->
       let force = Server_utils.bool_query_param req "force" ~default:false in
       let json = dashboard_runtime_probe_http_json ~force () in
       Http.Response.json_value ~compress:true ~request:req json reqd)
  (* Structured, already-resolved runtime defaults / model routing for the
     Settings surface. Read-only projection of the runtime.toml SSOT
     singletons (no credentials, no raw TOML), so a public read mirrors the
     other dashboard read surfaces. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/runtime-defaults" (fun _state req reqd ->
         let json =
           Server_dashboard_runtime_defaults_json.current
             ~generated_at_iso:(Masc_domain.now_iso ()) ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  (* Single resolved-runtime document (bugs #14/#15/#36): effective
     max-context + source per runtime, configured lanes, and the full
     keeper fleet joined against [runtime.assignments] with the
     [runtime].default rider made explicit. Read-only projection, same
     public-read posture as /api/v1/dashboard/runtime-defaults. *)
  |> Server_route.get Server_route.Public_read "/api/v1/runtime/resolved" (fun state req reqd ->
         let json =
           Server_dashboard_runtime_resolved_json.build
             ~generated_at_iso:(Masc_domain.now_iso ())
             ~config:(Mcp_server.workspace_config state)
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/sessions/official-client" (fun state _agent_name req reqd ->
           let keeper_name =
             Option.value
               (Server_utils.query_param req "keeper_name")
               ~default:""
           in
           let base_path = (Mcp_server.workspace_config state).base_path in
           respond_official_client_session_result
             req
             reqd
             (Official_client_session.snapshot ~base_path ~keeper_name))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/official-client/probe" (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let base_path = (Mcp_server.workspace_config state).base_path in
             respond_official_client_probe_result
               req
               reqd
               (Official_client_probe.probe_body ~base_path ~body)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/sessions/official-client/resolve" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             respond_official_client_session_result
               req
               reqd
               (Official_client_session.resolve_body
                  ~config:(Mcp_server.workspace_config state)
                  ~actor:agent_name
                  ~body)))
  |> Server_routes_http_routes_skills.add_routes
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/async-requests" (fun state _agent_name req reqd ->
           Http.Response.json_value
             ~compress:true
             ~request:req
             (Server_async_request_observability.project
                ~base_path:(Mcp_server.workspace_config state).base_path)
             reqd)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/async-requests/status" (fun state _agent_name req reqd ->
           let query = Uri.query (Uri.of_string req.Httpun.Request.target) in
           let values key = List.concat_map (fun (name,values) ->
             if String.equal name key then values else []) query in
           let payload = match values "submitted_by",values "request_id" with
             | [submitted_by],[request_id] ->
               Server_async_request_observability.project_request
                 ~base_path:(Mcp_server.workspace_config state).base_path ~submitted_by ~request_id
             | _ -> `Assoc ["schema",`String "masc.async-request-status/v1";
                 "status",`String "rejected";"reason",`String "single_submitted_by_and_request_id_required"] in
           Http.Response.json_value ~compress:true ~request:req payload reqd)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw" (fun _state _agent_name req reqd ->
           match Runtime.load_config_observation () with
           | Ok observation ->
             Http.Response.json_value ~compress:true ~request:req
               (runtime_config_raw_json
                  ~source_revision:observation.source_revision
                  ~path:observation.path
                  ~source_text:observation.source_text
                  ~operation:"read"
                  ~routing_applied_at:None
                  ())
               reqd
           | Error msg ->
             Keeper_api_types.respond_error
               ~status:(runtime_config_path_error_status msg)
               ~request:req reqd msg)
  (* RFC-0306 §3.1 — typed read of the active fusion config for the settings
     editor. [Fusion_config_loader.load] returns [Ok disabled] when runtime.toml
     or its [fusion] section is absent, and [Error] only when an existing section
     fails to parse/validate (a broken on-disk config), which surfaces as 500. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/fusion" (fun state _agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let runtime_config_path = Fusion_config_loader.runtime_toml_path ~base_path in
           (* The config and its revision come from one read, so the revision a
              client sends back names exactly the text it was shown. *)
           match Runtime.load_config_observation ~runtime_config_path () with
           | Error msg ->
             Keeper_api_types.respond_error
               ~status:(runtime_config_path_error_status msg)
               ~request:req reqd msg
           | Ok observation ->
             (match Otoml.Parser.from_string observation.source_text with
              | exception Otoml.Parse_error (_, msg) ->
                Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
                  ("runtime.toml parse error: " ^ msg)
              | toml ->
                (match Fusion_config.of_toml toml with
                 | Ok config ->
                   Http.Response.json_value ~compress:true ~request:req
                     (`Assoc
                       [ ("generated_at", `String (Masc_domain.now_iso ()))
                       ; ( "source_revision"
                         , `String
                             (Runtime.config_source_revision_to_string
                                observation.source_revision) )
                       ; ("config", Fusion_config_json.to_yojson config)
                       ])
                     reqd
                 | Error errors ->
                   Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
                     ("fusion config invalid: "
                      ^ String.concat "; "
                          (List.map Fusion_config.config_error_message errors)))))
  (* The memory recall gate as this server reads it now, per declared Keeper
     (see [Server_memory_recall_standing]): a settings form shows what a choice
     would change, and this is what stands today. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/memory-recall" (fun state _agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
           match Server_memory_recall_standing.read ~keepers_dir with
           | Error detail ->
             Keeper_api_types.respond_error ~status:`Internal_server_error ~request:req reqd
               ("keeper declarations could not be read: " ^ detail)
           | Ok standing ->
             Http.Response.json_value ~compress:true ~request:req
               (Server_memory_recall_standing.to_yojson
                  ~generated_at:(Masc_domain.now_iso ())
                  standing)
               reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/fusion" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_fusion_edit_body body_str with
             | Error msg ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
             | Ok (expected_revision, operation) ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let runtime_config_path =
                 Fusion_config_loader.runtime_toml_path ~base_path
               in
               let audit_operation =
                 Runtime_config_fusion (Fusion_config_edit.operation_label operation)
               in
               (match
                  Fusion_config_edit.apply ~runtime_config_path ~expected_revision operation
                with
                | Ok receipt ->
                  respond_runtime_config_commit state agent_name ~operation:audit_operation
                    ~receipt req reqd
                | Error error ->
                  audit_runtime_config_write state agent_name ~operation:audit_operation
                    ~text:body_str
                    ~outcome:(Audit_log.Failure (Fusion_config_edit.error_message error))
                    ();
                  let status =
                    match error with
                    | Fusion_config_edit.Configuration_changed -> `Conflict
                    | Fusion_config_edit.Configuration_unavailable _ -> `Internal_server_error
                    | Fusion_config_edit.Preset_invalid _
                    | Fusion_config_edit.Route_unresolved _
                    | Fusion_config_edit.Name_invalid _
                    | Fusion_config_edit.Default_preset_deleted _
                    | Fusion_config_edit.Edit_refused _
                    | Fusion_config_edit.Fusion_invalid _
                    | Fusion_config_edit.Configuration_rejected _ -> `Bad_request
                  in
                  Http.Response.json_value ~status ~request:req
                    (`Assoc
                       [ "ok", `Bool false
                       ; "error", Fusion_config_edit.error_to_yojson error
                       ])
                    reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw/preview" (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_config_raw_body body_str with
             | Error msg ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd msg
             | Ok source_text ->
               (match Keeper_runtime_config.validate_source_text source_text with
                | Error msg ->
                  Keeper_api_types.respond_error
                    ~status:`Bad_request
                    ~request:req
                    reqd
                    ("runtime config parse failed: " ^ msg)
                | Ok report ->
                  let schema_ok =
                    Keeper_runtime_config.validation_report_is_valid report
                  in
                  (* The raw-save path (Runtime.save_config_text) rejects text
                     that parses and passes the keeper schema but fails the
                     runtime parser. Run that same precondition here so can_save
                     cannot advertise a save guaranteed to fail. Mirror the save
                     order: the runtime check only runs once the schema is
                     valid. *)
                  let runtime_error =
                    if schema_ok
                    then (
                      match Runtime.validate_config_text source_text with
                      | Ok () -> None
                      | Error msg -> Some msg)
                    else None
                  in
                  let can_save = schema_ok && Option.is_none runtime_error in
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (`Assoc
                      [ "ok", `Bool true
                      ; "can_save", `Bool can_save
                      ; "validation", Keeper_runtime_config.validation_report_to_yojson report
                      ; ( "runtime_validation"
                        , match runtime_error with
                          | None -> `Null
                          | Some msg -> `String msg )
                      ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
                      ])
                    reqd)))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/setup/resume" (fun state _agent_name req reqd ->
           match Server_model_setup_resume.request
             ~base_path:(Mcp_server.workspace_config state).base_path with
           | Error error -> Keeper_api_types.respond_error ~status:`Service_unavailable
               ~request:req reqd (Server_model_setup_resume.error_message error)
           | Ok authority_available -> respond_json_value_with_cors req reqd
               (`Assoc ["runtime_ready", `Bool true;
                 "exact_output_authority_available", `Bool authority_available;
                 "model_setup", Runtime_startup_state.to_json ()]))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/raw" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_config_raw_post state agent_name req reqd body_str))
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/routing" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_routing_post state agent_name req reqd body_str
           )
         )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/runtime/config/assignment" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_assignment_post state agent_name req reqd body_str
           )
         )
  (* RFC-0482 §3.1: a terminal reader starts from the [tui] table the server
     writes, not from whichever runtime.toml its own environment finds. Only
     the settings are sent; the file carries provider configuration. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanReadState) "/api/v1/tui/preferences" (fun state _agent_name req reqd ->
         handle_tui_preferences_get state req reqd)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/tui/preferences" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_tui_preference_post state agent_name req reqd body_str))
  (* Phase 1 Action 2 — live Dashboard_cache state surface.  Renders
     hit_ratio, in-flight compute count, per-entry ttl_remaining, and
     timeout-circuit-open counts so operators can correlate slow endpoints
     (Server-Timing header) with cache contention without external telemetry.
     Read-only; no env tuning side-effect. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/cache-stats" (fun _state req reqd ->
         let json = Dashboard_cache.stats () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/logs" (fun state req reqd ->
         match Server_logs_query.of_request req with
         | Error json ->
           Http.Response.json_value ~status:`Bad_request ~compress:true ~request:req json reqd
         | Ok query ->
           let entries = Server_logs_query.read query in
           (* Bounds read after the slice: seqs are monotonic, so the
              window can only have grown — never claims more history
              than the slice actually had available. *)
           let ring_bounds = Log.Ring.bounds () in
           let json =
             Server_logs_query.to_json ~config:(Mcp_server.workspace_config state) query
               ~ring_bounds entries
           in
           Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_broadcast" }) "/api/v1/dashboard/logs/tool-host-failures" (fun state reported_by req reqd ->
         let request = req in Http.Request.read_body_async reqd (fun body_str ->
           let fallback_agent =
             dashboard_actor_for_request
               ~base_path:(Mcp_server.workspace_config state).base_path request
           in
           let report_result =
             try
               let json = Yojson.Safe.from_string body_str in
               Dashboard_tool_host_events.report_of_yojson ?fallback_agent json
             with Yojson.Json_error err ->
               Error ("invalid json: " ^ err)
           in
           match report_result with
           | Ok report ->
               Dashboard_tool_host_events.record ?fs:state.Mcp_server.fs
                 (Mcp_server.workspace_config state)
                 ~reported_by
                 report;
               respond_dashboard_ok ~request:req reqd
           | Error message ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [ ("ok", `Bool false); ("error", `String message) ])
                 reqd)
       )
  (* RFC-0049 — surface/section open counters. Aggregate Otel_metric_store
     counters only; the request body is discarded after increment. *)
  |> Server_route.post Server_route.Public_read "/api/v1/dashboard/nav-event" (fun _state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let result =
             try
               let json = Yojson.Safe.from_string body_str in
               Dashboard_nav_event.parse_event_json json
             with Yojson.Json_error err ->
               Error ("invalid json: " ^ err)
           in
           match result with
           | Ok event ->
               Dashboard_nav_event.record event;
               respond_dashboard_ok ~request:req reqd
           | Error message ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [ ("ok", `Bool false); ("error", `String message) ])
                 reqd)
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/config" (fun _state req reqd ->
         respond_cached_read ~request:req ~reqd ~cache_key:"config_introspect"
           ~ttl:config_cache_ttl_s
           (Pool_work.cpu ~name:__FUNCTION__ Env_config_introspect.to_json)
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/project-snapshot" (fun state req reqd ->
         let timing = Server_timing.create () in
         (* RFC-0138 Phase 3 Step 3: wait-free read via
            [Dashboard_snapshot.current ()].namespace_truth when the
            refresh fiber has populated it.  Cold start (or refresh
            spawned without ~state) falls through to the synchronous
            namespace-truth path inside the timing measurement. *)
         let json =
           Server_dashboard_snapshot_select.select_project_snapshot_json
             ~state ~sw ~clock ~timing req
         in
         Http.Response.json_value ~compress:true ~request:req ~extra_headers:(Server_timing.extra_header timing) json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/execution" (fun state req reqd ->
         (* The producer prepares all encodings once per snapshot. Requests
            select bytes and validate the identity ETag without recompression. *)
         let request = req in let timing = Server_timing.create () in
         let context, cached =
           Server_timing.measure timing Server_timing.Cache_lookup (fun () ->
             let context = execution_http_request ~state request in
             context, dashboard_execution_cached_http_response context)
         in
         let response = match cached with
           | Some response -> response
           | None -> Server_timing.measure timing Server_timing.Cache_compute
               (fun () -> dashboard_execution_http_response ~sw ~clock context) in
         (match response with
            | Execution_json json ->
              Http.Response.json_value ~compress:false ~request:req
                ~extra_headers:(Server_timing.extra_header timing) json reqd
            | Execution_payload payload ->
              let body, headers = Dashboard_cache.select_http_representation
                ~accept_encoding:(Httpun.Headers.get req.headers "accept-encoding") payload in
              Http.Response.json_lazy ~compress:false ~request:req ~etag:payload.etag
                ~extra_headers:(headers @ Server_timing.extra_header timing)
                (fun () -> body) reqd)
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/execution-trust" (fun state req reqd ->
         let request = req in let json =
           dashboard_execution_trust_http_json ~state ~sw ~clock request
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/board" (fun state req reqd ->
         Server_cached_read_http.respond ~request:req reqd
           (dashboard_memory_http_payload ~config:(Mcp_server.workspace_config state) req)
       )
  |> Server_route.post (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/link-previews" (fun state req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_dashboard_link_previews state req reqd body_str))
  |> Server_route.get (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/workspace-memory-ledger" (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let status, json = match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
             Workspace_memory_ledger_view.read ~base_path) with
             | Ok json -> `OK, json
             | Error detail -> `Service_unavailable, `Assoc ["error", `String detail] in
           Http.Response.json_value ~status ~request:req json reqd)
  |> Server_route.get (Server_route.Permission Masc_domain.CanReadState) "/api/v1/dashboard/workspace-memory-context" (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let json = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
             Server_dashboard_http_keeper_memory_health.workspace_memory_context_http_json
               ~base_path) in
           Http.Response.json_value ~compress:true ~request:req json reqd)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/keeper-memory-health" (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         (* [?keeper=] answers that Keeper's row alone, so a reader told that
            one Keeper's row moved reads that row instead of the fleet
            (RFC-0487). *)
         match Option.map String.trim (Server_utils.query_param req "keeper") with
         | None ->
           respond_cached_read ~request:req ~reqd
             ~cache_key:(Server_dashboard_http_keeper_memory_health.fleet_cache_key ~base_path)
             ~ttl:standard_cache_ttl_s (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
               Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json
                 ~base_path))
         | Some "" ->
           respond_json_value_with_cors ~status:`Bad_request req reqd
             (`Assoc [ "error", `String "keeper is empty" ])
         | Some keeper ->
           Http.Response.json_value ~compress:true ~request:req
             (Pool_work.submit
                (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
                   Server_dashboard_http_keeper_memory_health.keeper_memory_health_row_http_json
                     ~base_path ~keeper)))
             reqd)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/runtime-observables" (fun _state req reqd ->
         let json =
           Server_dashboard_http_runtime_observables.runtime_observables_http_json ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_routes_http_routes_keeper_gate.add_routes
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/proof" (fun state req reqd ->
         let json =
           dashboard_proof_http_json ~config:(Mcp_server.workspace_config state) req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/schedule/prune" (fun state operator_name request reqd ->
           let config = Mcp_server.workspace_config state in
           match dashboard_schedule_prune_http_json ~config ~operator_name with
           | Ok json -> respond_json_value_with_cors request reqd json
           | Error message ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (operator_error_json message)
         )

  |> Server_route.get Server_route.Public_read "/api/v1/operator" (fun state req reqd ->
         let json =
           operator_snapshot_http_json
             ~state
             ~sw
             ~clock
             ~broadcast_snapshot:
               Server_dashboard_http_execution_surfaces
               .broadcast_operator_snapshot
             req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/operator/digest" (fun state req reqd ->
         let request = req in match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json_value ~compress:true ~request:req json reqd
         | Error message ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
       )
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_operator_action" }) "/api/v1/operator/action" (fun state authorized_actor req reqd ->
         let request = req in Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               operator_action_http_json
                 ~state
                 ~sw
                 ~clock
                 ~authorized_actor
                 req
                 ~args
             with
             | Ok json ->
                 respond_json_value_with_cors request reqd json
             | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
           with Yojson.Json_error msg ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (Printf.sprintf "invalid json: %s" msg))
         )
       )
  |> Server_route.post (Server_route.Tool_actor { tool_name = "masc_operator_confirm" }) "/api/v1/operator/confirm" (fun state authorized_actor req reqd ->
         let request = req in Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match
               operator_confirm_http_json
                 ~state
                 ~sw
                 ~clock
                 ~authorized_actor
                 req
                 ~args
             with
             | Ok json ->
                 respond_json_value_with_cors request reqd json
             | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
           with Yojson.Json_error msg ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (Printf.sprintf "invalid json: %s" msg))
         )
       )

  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/planning" (fun state req reqd ->
         Server_cached_read_http.respond ~request:req reqd
           (cached_planning_payload ~config:(Mcp_server.workspace_config state))
       )
  (* Cold-start bootstrap: routes to the shared SSOT
     [dashboard_bootstrap_http_json] in [Server_dashboard_http] so
     the HTTP/1.1 router and HTTP/2 gateway return identical
     payloads.  Slice list, error contract, and per-slice
     exception capture all live in the SSOT; this handler is
     just the auth + transport wrapper. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/bootstrap" (fun state req reqd ->
         let json = dashboard_bootstrap_http_json ~state ~sw ~clock req in
         Http.Response.json_value_on_cpu ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/goals" (fun state req reqd ->
         let scope = Mcp_server.workspace_scope state in
         let config = scope.config in
         match Server_auth.validate_read_workspace_precondition ~config req with
         | Ok Server_auth.Workspace_read_unbound ->
           Server_cached_read_http.respond ~request:req reqd (cached_goals_tree_payload ~config)
         | Ok Server_auth.Workspace_read_matched ->
           let accept_encoding = Http_response_payload.accept_encoding_fields
             (Httpun.Headers.get_multi req.headers "accept-encoding") in
           let json, body, encoding_headers = match direct_goals_tree_payload ~scope ~accept_encoding with
             | Ok (json, body, headers) -> json, body, headers
             | Error json ->
               let body, headers = Http_response_payload.compress_body ~accept_encoding (Yojson.Safe.to_string json) in
               json, body, headers in
           let status = Http.Response.timeout_envelope_status_override ~status:`OK json in
           let respond_changed_scope () =
             respond_goal_tree_workspace_refusal req reqd Workspace.Workspace_precondition_failed in
           let still_matched () = goal_tree_scope_current state scope &&
             match Server_auth.validate_read_workspace_precondition ~config req with
             | Ok Server_auth.Workspace_read_matched -> true
             | Ok Server_auth.Workspace_read_unbound | Error _ -> false in
           if still_matched () then
             Http.Response.bytes ~status
               ~headers:(encoding_headers @ ("cache-control", "private, no-store") ::
                 Server_utils.goal_tree_direct_read_header :: public_read_cors_headers req)
               ~content_type:"application/json; charset=utf-8" body reqd
           else respond_changed_scope ()
         | Error error ->
           respond_goal_tree_workspace_refusal req reqd error
       )
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/goals/candle" (fun state _actor req reqd ->
         let config = Mcp_server.workspace_config state in
         let status, json = Server_dashboard_goal_candle.response ~config req in
         let status = Http.Response.timeout_envelope_status_override ~status json in
         (* This live, credential-bound observation must not be converted to a
            conditional 304 by the general JSON responder. *)
         Http.Response.bytes ~status
           ~headers:(["cache-control", "private, no-store"] @ Server_dashboard_goal_candle.generation_headers @ public_read_cors_headers req)
           ~content_type:"application/json; charset=utf-8" (Yojson.Safe.to_string json) reqd
       )
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/goals/measurements" (fun state actor req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let answer =
               try
                 let json = Yojson.Safe.from_string body in
                 let config = Mcp_server.workspace_config state in
                 Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                   Goal_measurement.record_json config ~actor json)
               with Yojson.Json_error detail ->
                 Error (Goal_measurement.Invalid_request ("invalid JSON: " ^ detail))
             in
             match answer with
             | Error error ->
                 let status =
                   match error with
                   | Goal_measurement.Invalid_request _ -> `Bad_request
                   | Goal_measurement.Conflict _ -> `Conflict
                   | Goal_measurement.Store_error _ -> `Service_unavailable
                 in
                 respond_json_value_with_cors ~status req reqd
                   (Keeper_api_types.error_json ~ok:false
                      (Goal_measurement.error_to_string error))
             | Ok receipt ->
                 respond_json_value_with_cors req reqd
                   (`Assoc (("ok", `Bool true)
                            :: Goal_measurement.receipt_fields receipt))))
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/goals/detail" (fun state req reqd ->
         let config = Mcp_server.workspace_config state in
         match Server_auth.validate_read_workspace_precondition ~config req with
         | Error error ->
           let body, status = Server_auth.read_workspace_precondition_error_response error in
           respond_json_value_with_cors ~status req reqd body
         | Ok (Server_auth.Workspace_read_unbound | Server_auth.Workspace_read_matched) ->
         let goal_id =
           Server_utils.query_param req "goal_id"
           |> Option.map String.trim
           |> Option.value ~default:""
         in
         if goal_id = "" then
           respond_public_read_json_value ~status:`Bad_request req reqd
             (Keeper_api_types.error_json ~ok:false "goal_id query param is required")
         else
           let cache_key =
             Printf.sprintf "goal_detail:%s:%s:%d" (goal_cache_scope ~config) goal_id
               (Goal_projection_generation.current ())
           in
           respond_cached_read ~request:req ~reqd ~cache_key ~ttl:standard_cache_ttl_s
             (Pool_work.cpu ~name:__FUNCTION__ (fun () -> dashboard_goal_detail_http_json ~config ~goal_id))
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tasks/search-text" (fun state req reqd ->
         let config = Mcp_server.workspace_config state in
         let status, json = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
           Server_dashboard_task_search_text.read ~config)
           |> Server_dashboard_task_search_text.response in
         Http.Response.json_value ~status:(status :> Httpun.Status.t)
           ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tasks/detail" (fun state req reqd ->
         let task_id = Server_utils.query_param req "task_id" in
         let config = Mcp_server.workspace_config state in
         let status, json = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
           Server_dashboard_task_detail.read ~config ~task_id)
           |> Server_dashboard_task_detail.response in
         Http.Response.json_value ~status:(status :> Httpun.Status.t)
           ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tasks/inspection" (fun state req reqd ->
         let task_id=Server_utils.query_param req "task_id" in
         let config=Mcp_server.workspace_config state in
         let status,json=Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
           Server_dashboard_task_detail.inspect ~config ~task_id)
           |> Server_dashboard_task_detail.inspection_response in
         Http.Response.json_value ~status:(status :> Httpun.Status.t)
           ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tasks/history/page" (fun state req reqd ->
         Server_routes_http_dashboard_handlers.handle_dashboard_task_history_page state req reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tasks/history" (fun state req reqd ->
         handle_dashboard_task_history state req reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/briefing" (fun state req reqd ->
         let cache_key =
           Server_dashboard_http_core_cache.dashboard_query_cache_key
             (Mcp_server.workspace_config state)
             "briefing"
             [ ("actor", dashboard_actor_cache_segment state req) ]
         in
         respond_cached_read ~request:req ~reqd ~cache_key ~ttl:live_cache_ttl_s
           (Pool_work.cpu ~name:__FUNCTION__ (fun () -> dashboard_briefing_http_json ~state ~sw ~clock req))
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/health-line" (fun state req reqd ->
         (* Not cached here: a reader reads after a workspace_health push, and
            the mission it is taken from is the server's own cache. *)
         let json =
           Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
               dashboard_health_line_http_json ~state ~sw ~clock)
         in
         Http.Response.json_value ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tools" (fun state req reqd ->
           let request = req in let timing = Server_timing.create () in
           (* RFC-0138 Phase 3 Step 2: wait-free read via
              [Dashboard_snapshot.current ()] for the global catalog. An exact
              Keeper selector computes the effective surface beside it. *)
           let response =
             Server_dashboard_snapshot_select.select_tools_response
               ~timing
               ?keeper:(Server_utils.query_param request "keeper")
               (Mcp_server.workspace_config state)
           in
           let extra_headers = public_read_cors_headers req @ Server_timing.extra_header timing in
           match response with
           | Server_dashboard_snapshot_select.Tools_json json ->
             Http.Response.json_value ~compress:true ~request:req
               ~extra_headers json reqd
           | Tools_prepared tools ->
             let body, headers = Http_response_payload.select_prepared
               ~accept_encoding:(Httpun.Headers.get req.headers "accept-encoding")
               tools.encoded in
             Http.Response.json_lazy ~compress:false ~request:req ~etag:tools.etag
               ~extra_headers:(headers @ extra_headers)
               (fun () -> body) reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/skill-activations" (fun state req reqd ->
         let extra_headers = public_read_cors_headers req in
         match Server_utils.query_param req "trace_id" |> Option.map String.trim with
         | None | Some "" ->
           Http.Response.json_value ~compress:true ~request:req
             ~status:`Bad_request ~extra_headers
             (Keeper_api_types.error_json "trace_id query param is required") reqd
         | Some raw_trace_id ->
           (match
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                Keeper_skill_activation_projection.resolve_trace_string
                  ~config:(Mcp_server.workspace_config state)
                  raw_trace_id)
            with
            | Error detail ->
              Http.Response.json_value ~compress:true ~request:req
                ~status:`Bad_request ~extra_headers
                (Keeper_api_types.error_json detail) reqd
            | Ok projection ->
              let json =
                Keeper_skill_activation_projection.trace_to_yojson projection
              in
              Http.Response.json_value ~compress:true ~request:req
                ~extra_headers json reqd)
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/skill-activations/physical-turn" (fun state req reqd ->
         let extra_headers = public_read_cors_headers req in
         match Server_utils.query_param req "turn_ref" with
         | None ->
           Http.Response.json_value ~compress:true ~request:req
             ~status:`Bad_request ~extra_headers
             (Keeper_api_types.error_json "turn_ref query param is required") reqd
         | Some raw_turn_ref ->
           (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              Server_skill_physical_turn.project_string
                ~config:(Mcp_server.workspace_config state) raw_turn_ref) with
            | Error detail ->
              Http.Response.json_value ~compress:true ~request:req
                ~status:`Bad_request ~extra_headers (Keeper_api_types.error_json detail) reqd
            | Ok json ->
              Http.Response.json_value ~compress:true ~request:req ~extra_headers json reqd))
  (* Schedule projection, served by its owner. The no-query aggregate keeps its
     shared live cache; an exact schedule_id lookup reads the same ledger and
     row encoder without adding a client-controlled cache key. *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/scheduled-automation" (fun state req reqd ->
         let json =
           Server_dashboard_http.dashboard_scheduled_automation_query_http_json
             ~config:(Mcp_server.workspace_config state)
             req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/briefing/sections" (fun state req reqd ->
         if Server_utils.bool_query_param req "force" ~default:false then
           Http.Response.json_value ~compress:true ~request:req
             (Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                dashboard_briefing_sections_http_json ~state ~sw ~clock req))
             reqd
         else
           let cache_key =
             Server_dashboard_http_core_cache.dashboard_query_cache_key
               (Mcp_server.workspace_config state)
               "mission_briefing"
               [ ("actor", dashboard_actor_cache_segment state req) ]
           in
           respond_cached_read ~request:req ~reqd ~cache_key ~ttl:live_cache_ttl_s
             (Pool_work.cpu ~name:__FUNCTION__ (fun () -> dashboard_briefing_sections_http_json ~state ~sw ~clock req))
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/tool-quality" (fun state req reqd ->
         let n =
           let raw = match Server_utils.query_param req "n" with
             | Some s -> int_of_string_opt s |> Option.value ~default:5000
             | None -> 5000
           in
           max 1 (min 50000 raw)
         in
         let window_hours =
           match Server_utils.query_param req "window_hours" with
           | Some s ->
             (match float_of_string_opt s with
              | Some value -> Some (max 0.1 (min 168.0 value))
              | None -> None)
           | None -> None
         in
         let sampling = Dashboard_http_tool_quality.select_sampling ~n ?window_hours () in
         let sampling_key = match sampling with
           | Dashboard_http_tool_quality.Window_hours hours ->
             `List [`String "window_hours"; `String (Printf.sprintf "%h" hours)]
           | Dashboard_http_tool_quality.Recent_n count ->
             `List [`String "recent_n"; `Int count] in
         let cache_key =
           Server_dashboard_http_core_cache.dashboard_cache_key
             (Mcp_server.workspace_config state) "tool_quality"
             (Yojson.Safe.to_string sampling_key)
         in
         (* TTL extended 5s→30s — [aggregate] over a 24h window was
            measured at 30s cache miss (curl --max-time 30 timeout in the
            page→endpoint profile). The window itself is hours-scale so
            6× longer TTL still serves near-live data; under 30s window the
            poll just hit the previous compute and never wait 30s again. *)
         (* [Dashboard_cache.get_or_compute_payload] takes a
            [unit -> Yojson.Safe.t] compute and must not store a 503 for the
            TTL, so the typed read failure leaves the compute as an exception:
            the cache drops the computing slot and re-raises when it has
            nothing stale to serve, and the route answers 503 rather than a
            payload with zero calls (audit F397). *)
         let payload =
           match
             Dashboard_cache.get_or_compute_payload cache_key ~ttl:config_cache_ttl_s
               (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
                  match Dashboard_http_tool_quality.aggregate sampling with
                  | Ok json -> json
                  | Error (Keeper_tool_call_log.Index_unavailable detail) ->
                    raise (Tool_quality_log_unavailable detail)))
           with
           | payload -> Ok payload
           | exception Tool_quality_log_unavailable detail -> Error detail
         in
         match payload with
         | Ok payload -> Server_cached_read_http.respond ~request:req reqd payload
         | Error detail ->
           Http.Response.json_value
             ~status:`Service_unavailable
             ~compress:true
             ~request:req
             (`Assoc
                [ "error", `String detail
                ; "code", `String "tool_call_store_unavailable"
                ])
             reqd
       )
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/diagnostics/memprof" (fun _state _agent_name req reqd ->
            let json = Server_diagnostics_memprof.report_json () in
            Http.Response.json_value ~compress:true ~request:req json reqd)
  (* Operator diagnostic, never cached and never public: the walk stalls
     the process, so only an admin token may ask for it, and each call
     must walk afresh to say what the heap holds now. *)
  |> Server_route.get (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/diagnostics/heap-roots" (fun _state _agent_name req reqd ->
            let json = Server_diagnostics_heap_roots.report_json () in
            Http.Response.json_value ~compress:true ~request:req json reqd)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/transport-health" (fun state req reqd ->
         (* No route cache here. The producer is not a computation — it reads a
            published cell and derives cache_state, stale_reason and
            stale_age_ms from it. A second 30s cache in front of that served
            the previous "fresh" payload after the inner surface had gone to an
            error state, and froze stale_age_ms, so a client watching the age
            saw it stand still while the surface aged (#27652). Every other
            route cache on this router wraps an actual computation. *)
         let json = dashboard_transport_health_http_json ~state in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/clients" (fun state req reqd ->
         (* Everyone attached to this workspace in one reading: directory
            agents, state-backed sessions, and runtime fibers, merged with
            each row's source by [Workspace.get_active_agent_sources_observed].
            The TUI's Runtime family reads this to answer "who is connected",
            which no other surface lists — the keeper roster carries keepers
            only, so a non-keeper MCP client is invisible there. Sorted by
            name so two readings a refresh apart diff as row changes, not
            reorderings. Observation-only: joining a session to its task
            binding is a read, and the backlog stays the authority on
            ownership. *)
         let config = Mcp_server.workspace_config state in
         let rows, read_failures =
           Workspace.get_active_agent_sources_observed config
         in
         let sorted =
           List.sort
             (fun ((a : Masc_domain.agent), _) ((b : Masc_domain.agent), _) ->
                String.compare a.name b.name)
             rows
         in
         let json =
           `Assoc
             [ ("schema", `String "masc.dashboard.clients.v2")
             ; ("generated_at", `String (Masc_domain.now_iso ()))
             ; ("observation_only", `Bool true)
             ; ( "clients"
               , `List
                   (List.map
                      Server_dashboard_http_core_entities.dashboard_client_json
                      sorted) )
               (* A source that could not be read leaves its rows out; the
                  reader is told so and reads again rather than taking the
                  shorter roster as the whole one. *)
             ; ("read_failures", `List (List.map (fun detail -> `String detail) read_failures))
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/harness-health" (fun state req reqd ->
         let since = Server_utils.query_param req "since" in
         let until = Server_utils.query_param req "until" in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let cache_key =
           Printf.sprintf "%s%s:%s:%s" Dashboard_harness_health.cache_key_prefix
             base_path
             (Option.value ~default:"-" since)
             (Option.value ~default:"-" until)
         in
         respond_cached_read ~request:req ~reqd ~cache_key ~ttl:standard_cache_ttl_s
           (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
              Dashboard_harness_health.json ?since ?until ~base_path ()))
       )
  (* An operator's own verdict on a harness row. The label is ground truth
     for judge calibration, so it takes the admin permission and the
     authenticated caller becomes the labeler — no anonymous ground truth. *)
  |> Server_route.post (Server_route.Token_permission Masc_domain.CanAdmin) "/api/v1/dashboard/harness-label" (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match Dashboard_harness_health.parse_label_body body_str with
             | Error message ->
               Keeper_api_types.respond_error ~status:`Bad_request ~request:req reqd message
             | Ok label ->
               Dashboard_harness_health.record_operator_label
                 ~base_path:(Mcp_server.workspace_config state).base_path
                 ~labeler:agent_name label;
               Http.Response.json_value ~request:req
                 (`Assoc [ "ok", `Bool true ]) reqd))
  (* ── Eval feed (RFC-MASC-005 Phase 2) ── *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/eval-feed" (fun state req reqd ->
         let config = Mcp_server.workspace_config state in
         let base_path = config.base_path in
         let agent_name = Server_utils.query_param req "agent_name" |> Option.map String.trim in
         let limit =
           Server_utils.int_query_param req "limit" ~default:10
           |> max 1 |> min 100
         in
         (* Keep identity beside the selected read: the fleet always reads
            one snapshot per agent, while an exact agent uses [limit]. *)
         let scope, compute =
           match agent_name with
           | Some name when name <> "" ->
             (`List [`String "agent"; `String name; `Int limit], fun () ->
               let snapshots =
                 Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
               in
               `Assoc [
                 ("generated_at", `String (Masc_domain.now_iso ()));
                 ("agent_name", `String name);
                 ("count", `Int (List.length snapshots));
                 ("snapshots", `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots));
               ])
           | Some _ | None ->
             (`List [`String "all"], fun () ->
               let agents = Dashboard_eval_feed.list_agents ~base_path in
               let per_agent =
                 List.map (fun name ->
                   let snapshots =
                     Dashboard_eval_feed.read_latest ~base_path
                       ~agent_name:name ~limit:1
                   in
                   let latest =
                     match snapshots with
                     | s :: _ -> Dashboard_eval_feed.snapshot_to_json s
                     | [] -> `Null
                   in
                   `Assoc [
                     ("agent_name", `String name);
                     ("latest", latest);
                   ]
                 ) agents
               in
               `Assoc [
                 ("generated_at", `String (Masc_domain.now_iso ()));
                 ("agent_count", `Int (List.length agents));
                 ("agents", `List per_agent);
               ])
         in
         let cache_key =
           Server_dashboard_http_core_cache.dashboard_cache_key config
             "eval_feed" (Yojson.Safe.to_string scope)
         in
         respond_cached_read ~request:req ~reqd ~cache_key ~ttl:standard_cache_ttl_s
           (Pool_work.cpu ~name:__FUNCTION__ compute)
       )

  (* ── Telemetry unified view ── *)
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/telemetry" handle_telemetry
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/telemetry/summary" (fun state req reqd ->
         let timing = Server_timing.create () in
         (* RFC-0138 Phase 3 Step 2: wait-free read via
            [Dashboard_snapshot.current ()].telemetry_summary when the
            refresh fiber has published; falls back through the same
            [Dashboard_cache] + [Telemetry_unified.summary_json] path
            for cold start. *)
         let json =
           Server_dashboard_snapshot_select.select_telemetry_summary_json
             ~timing (Mcp_server.workspace_config state)
         in
         Http.Response.json_value ~compress:true ~request:req ~extra_headers:(Server_timing.extra_header timing) json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/agent_core/telemetry/recent" (fun _state req reqd ->
         let provider = agent_core_telemetry_provider_param req in
         let limit = agent_core_telemetry_limit_param req in
         let json = Dashboard_agent_core_bridge.recent_json ?provider ~limit () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/dashboard/agent_core/telemetry/summary" (fun _state req reqd ->
         let provider = agent_core_telemetry_provider_param req in
         let limit = agent_core_telemetry_limit_param req in
         let json = Dashboard_agent_core_bridge.summary_json ?provider ~limit () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       )

  (* ── Dashboard delete actions (extracted) ── *)
  |> Server_dashboard_http_delete_actions.add_delete_action_routes

  (* ── Keeper routes (extracted) ── *)
  |> Server_routes_http_routes_keepers.add_routes ~sw ~clock

  (* ── Agent API routes (extracted) ── *)
  |> Server_dashboard_http_agent_api.add_agent_api_routes
