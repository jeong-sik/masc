(* server_routes_http_routes_dashboard — dashboard route registration.

   Setup (module aliases, helpers, handlers) and telemetry endpoint
   extracted to Server_routes_http_routes_dashboard_setup as part of
   godfile near-threshold split. *)

open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

include Server_routes_http_routes_dashboard_setup

module Keeper_chat_operations = Server_dashboard_http_keeper_chat_operations
module Keeper_event_queue_operator =
  Server_dashboard_http_keeper_event_queue_operator
module Official_client_session = Server_dashboard_official_client_session
module Official_client_probe = Server_dashboard_official_client_probe

let config_cache_ttl_s = Server_dashboard_http_core_cache.config_cache_ttl_s
let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let live_cache_ttl_s = Server_dashboard_http_core_cache.live_cache_ttl_s
let feature_health_cache_ttl_s = Server_dashboard_http_core_cache.feature_health_cache_ttl_s
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

let dashboard_error_json ?ok message =
  let fields = [ ("error", `String message) ] in
  let fields =
    match ok with
    | None -> fields
    | Some value -> ("ok", `Bool value) :: fields
  in
  `Assoc fields

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

let respond_dashboard_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http.Response.json_value ?request ~status
    (dashboard_error_json ?ok message)
    reqd

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

let handle_execute_output_stream ~sw ~clock request reqd =
  with_public_read
    (fun _state req inner_reqd ->
       let path = Http.Request.path req in
       let keeper =
         match
           Server_utils.extract_path_param
             ~prefix:"/api/dashboard/execute-output/"
             path
         with
         | Some value -> Some value
         | None ->
           Server_utils.extract_path_param
             ~prefix:"/api/v1/dashboard/execute-output/"
             path
       in
       match keeper with
       | None ->
         respond_dashboard_error
           ~status:`Bad_request
           ~request:req
           inner_reqd
           "keeper path parameter is required"
       | Some keeper ->
         let keeper_name = Uri.pct_decode keeper |> String.trim in
         let origin = get_origin req in
         let headers =
           Httpun.Headers.of_list
             ([ "content-type", "text/event-stream"
              ; "cache-control", "no-cache"
              ; "connection", "keep-alive"
              ; "x-accel-buffering", "no"
              ]
              @ cors_headers origin)
         in
         let response = Httpun.Response.create ~headers `OK in
         let writer = Httpun.Reqd.respond_with_streaming inner_reqd response in
         let closed = ref false in
         let close_stream () =
           if not !closed
           then (
             closed := true;
             try Httpun.Body.Writer.close writer with
             | exn ->
               Log.Dashboard.warn
                 "execute output stream close failed: %s"
                 (Printexc.to_string exn))
         in
         let write_string data =
           if !closed
           then false
           else (
             try
               Httpun.Body.Writer.write_string writer data;
               true
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn ->
               Log.Dashboard.warn
                 "execute output stream write failed: %s"
                 (Printexc.to_string exn);
               close_stream ();
               false)
         in
         let write_json json =
           write_string (Dashboard_execute_output.sse_frame json)
         in
         match Dashboard_execute_output.subscribe ~keeper_name with
         | None ->
           (* fire-and-forget: best-effort terminal event before closing stream. *)
           ignore (write_json (Dashboard_execute_output.event_json ~keeper_name));
           close_stream ()
         | Some subscriber ->
           let wrote_initial =
             write_string
               (Printf.sprintf "retry: %d\n\n" sse_dashboard_retry_backoff_ms)
             && write_json (Dashboard_execute_output.event_json ~keeper_name)
           in
           if not wrote_initial
           then Dashboard_execute_output.unsubscribe subscriber
           else
             Eio.Fiber.fork ~sw (fun () ->
               Eio.Switch.run (fun stream_sw ->
                 Server_bootstrap_http.with_cleanups_on_release ~sw:stream_sw
                   [
                     (fun () -> Dashboard_execute_output.unsubscribe subscriber);
                     close_stream;
                   ];
                 let rec loop () =
                   if not !closed
                   then (
                     match
                       Eio.Time.with_timeout clock execute_output_heartbeat_s (fun () ->
                         Ok (Dashboard_execute_output.take_event subscriber))
                     with
                     | Ok event ->
                       if
                         write_json
                           (Dashboard_execute_output.stream_event_json event)
                       then loop ()
                     | Error `Timeout ->
                       if write_string ": heartbeat\n\n" then loop ())
                 in
                 try loop () with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | exn ->
                   Log.Dashboard.warn
                     "execute output stream loop failed: %s"
                     (Printexc.to_string exn);
                   close_stream ())))
    request
    reqd

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

let keeper_setting_payload source_text =
  match Keeper_toml_loader.parse_toml source_text with
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

let skill_config_state_label snapshot =
  match Skill_catalog_snapshot.config_state snapshot with
  | Configured _ -> "configured"
  | Config_rejected _ -> "rejected"
  | Config_unreadable _ -> "unreadable"
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
        ; "config_state", `String (skill_config_state_label snapshot)
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

let runtime_config_commit_json (receipt : Runtime.config_commit_receipt) =
  `Assoc
    [ ( "source_revision"
      , `String
          (Runtime.config_source_revision_to_string
             receipt.observation.source_revision) )
    ; ( "order"
      , `String (Runtime.config_commit_order_to_string receipt.order) )
    ; ( "durability"
      , `String
          (match receipt.durability with
           | Runtime.Durable -> "durable"
           | Durability_unconfirmed _ -> "unconfirmed") )
    ; ( "warnings"
      , `List
          (List.map Runtime.config_lock_warning_to_yojson receipt.lock_warnings) )
    ]
;;

let runtime_config_application_json
      ?skill_application
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
     @ match skill_application with
       | None -> []
       | Some application -> [ "skills", skill_application_json application ])
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
  let validation, keeper_settings, overlay = keeper_setting_payload source_text in
  `Assoc
    ([ ("ok", `Bool true)
    ; ( "source_revision"
      , `String (Runtime.config_source_revision_to_string source_revision) )
    ; ("path", `String path)
    ; ("file_name", `String "runtime.toml")
    ; ("source_text", `String source_text)
    ; ( "application"
      , runtime_config_application_json
          ?skill_application
          ~operation
          ~routing_applied_at
          overlay )
    ; "validation", validation
    ; "keeper_setting_schema", Keeper_runtime_config.setting_schema_to_yojson ()
    ; "keeper_settings", keeper_settings
    ; ( "provider_protocols"
      , `List (List.map runtime_editor_protocol_json Runtime_toml.editor_protocols) )
    ]
     @ match commit with
       | None -> []
       | Some receipt ->
         [ "state", `String "committed"
         ; "commit", runtime_config_commit_json receipt
         ])

(* Line count for the audit [lines] metric. [String.split_on_char '\n'] counts a
   trailing newline as an extra empty line ("a\nb\n" -> 3 elements), so count
   newline-separated lines treating a final '\n' as terminating the last line
   rather than starting a new one ("a\nb\n" -> 2). *)
let runtime_config_line_count text =
  if String.length text = 0
  then 0
  else (
    let newlines =
      String.fold_left (fun n c -> if Char.equal c '\n' then n + 1 else n) 0 text
    in
    if Char.equal text.[String.length text - 1] '\n' then newlines else newlines + 1)

let parse_runtime_config_raw_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match Json_util.assoc_member_opt "source_text" json with
       | Some (`String source_text) -> Ok source_text
       | Some _ -> Error "source_text must be a string"
       | None -> Error "source_text required")
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

type skill_editor_body =
  { reference : Skill_reference.t
  ; source_text : string option
  ; confirmed : bool option
  }

let parse_skill_editor_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match Json_util.assoc_member_opt "reference" json with
       | None -> Error "reference required"
       | Some reference_json ->
         (match Skill_reference.of_yojson reference_json with
          | Error _ -> Error "reference must be an exact Skill reference"
          | Ok reference ->
            let ( let* ) = Result.bind in
            let* source_text =
              match Json_util.assoc_member_opt "source_text" json with
              | None -> Ok None
              | Some (`String source_text) -> Ok (Some source_text)
              | Some _ -> Error "source_text must be a string"
            in
            let* confirmed =
              match Json_util.assoc_member_opt "confirmed" json with
              | None -> Ok None
              | Some (`Bool confirmed) -> Ok (Some confirmed)
              | Some _ -> Error "confirmed must be a boolean"
            in
            Ok { reference; source_text; confirmed }))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

type skill_create_body =
  { source_id : Skill_source_config.source_id
  ; package_id : string
  ; source_text : string
  }

let parse_skill_create_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      let ( let* ) = Result.bind in
      let required name =
        match Json_util.assoc_member_opt name json with
        | Some (`String value) when not (String.equal (String.trim value) "") ->
          Ok (String.trim value)
        | Some (`String _) -> Error (name ^ " must not be empty")
        | Some _ -> Error (name ^ " must be a string")
        | None -> Error (name ^ " required")
      in
      let* source_id_text = required "source_id" in
      let* source_id =
        Skill_source_config.source_id_of_string source_id_text
        |> Result.map_error (fun detail -> "invalid source_id: " ^ detail)
      in
      let* package_id = required "package_id" in
      let* source_text =
        match Json_util.assoc_member_opt "source_text" json with
        | Some (`String value) when not (String.equal value "") -> Ok value
        | Some (`String _) -> Error "source_text must not be empty"
        | Some _ -> Error "source_text must be a string"
        | None -> Error "source_text required"
      in
      Ok { source_id; package_id; source_text }
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

let skill_editor_error_status = function
  | Server_skill_editor.Source_read_only -> `Forbidden
  | Revision_conflict _ | Delete_revision_conflict _ | Recovery_required _
  | Package_already_exists ->
    `Conflict
  | Snapshot_not_registered | Snapshot_uninitialized | Reference_not_current
  | Source_not_ready | Source_file_missing ->
    `Not_found
  | Invalid_workspace | Source_read_failed | Write_failed _ | Quarantine_failed _ ->
    `Internal_server_error
  | Source_too_large _ -> `Payload_too_large
  | Source_path_rejected _ | Confirmation_required | Invalid_package_id _
  | Validation_failed _ ->
    `Bad_request

let respond_skill_editor_error ~request reqd error =
  Http.Response.json_value
    ~status:(skill_editor_error_status error)
    ~request
    (Server_skill_editor.error_to_yojson error)
    reqd
;;

type runtime_route_lane =
  | Runtime_default
  | Runtime_media_failover
  | Runtime_named_lane of string
      (** A [\[runtime.lanes."<id>"\]] failover ladder. The id is a runtime id:
          a lane shadows the runtime it is named after, which is how an
          assignment reaches it. *)

let runtime_route_lane_to_string = function
  | Runtime_default -> "default"
  | Runtime_media_failover -> "media_failover"
  | Runtime_named_lane lane_id -> lane_id

(* An unrecognised name used to be rejected outright, which left the Runtime
   screen's failover picker with nowhere to post: it names the lane under the
   cursor, and those are runtime ids. A name is admitted when the runtime
   resolver knows it — [resolve_assignment] answers [`Missing] for an id that
   is neither a declared lane nor a configured runtime — so a typo is still
   refused, and it is refused with the name it could not find. *)
let parse_runtime_route_lane = function
  | "default" -> Ok Runtime_default
  | "media_failover" -> Ok Runtime_media_failover
  | lane ->
    (match Runtime.resolve_assignment lane with
     | `Lane _ -> Ok (Runtime_named_lane lane)
     | `Missing ->
       Error
         (Printf.sprintf
            "unknown runtime routing lane: %s (not a declared lane or a \
             configured runtime)"
            lane))

type runtime_route_body =
  | Runtime_route_runtime_id of runtime_route_lane * string option
  | Runtime_route_runtime_ids of runtime_route_lane * string list

let required_string_field json name =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) when not (String.equal (String.trim value) "") ->
    Ok (String.trim value)
  | Some (`String _) -> Error (name ^ " must not be empty")
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " required")

let optional_string_field json name =
  match Json_util.assoc_member_opt name json with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then Ok None else Ok (Some trimmed)
  | Some _ -> Error (name ^ " must be a string or null")

let required_string_array_field json name =
  match Json_util.assoc_member_opt name json with
  | Some (`List values) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest ->
        let trimmed = String.trim value in
        if String.equal trimmed ""
        then Error (name ^ " must not contain empty entries")
        else loop (trimmed :: acc) rest
      | _ :: _ -> Error (name ^ " must be an array of strings")
    in
    loop [] values
  | Some _ -> Error (name ^ " must be an array of strings")
  | None -> Error (name ^ " required")
;;

let parse_runtime_route_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match required_string_field json "lane" with
       | Error _ as err -> err
       | Ok lane ->
         (match parse_runtime_route_lane lane with
         | Error _ as err -> err
         | Ok parsed_lane ->
           (match parsed_lane with
            | Runtime_media_failover ->
              (match required_string_array_field json "runtime_ids" with
               | Error _ as err -> err
               | Ok runtime_ids ->
                 Ok (Runtime_route_runtime_ids (parsed_lane, runtime_ids)))
            | _ ->
              (match optional_string_field json "runtime_id" with
               | Error _ as err -> err
               | Ok runtime_id ->
                 Ok (Runtime_route_runtime_id (parsed_lane, runtime_id))))))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

let parse_runtime_assignment_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match required_string_field json "keeper_name" with
       | Error _ as err -> err
       | Ok keeper_name ->
         if not (Keeper_config.validate_name keeper_name)
         then Error (Printf.sprintf "invalid keeper name: %S" keeper_name)
         else (match optional_string_field json "runtime_id" with
          | Error _ as err -> err
          | Ok runtime_id ->
            (match Json_util.assoc_member_opt "expected_assignment_revision" json with
             | None -> Error "expected_assignment_revision required"
             | Some value ->
               Runtime.keeper_assignment_revision_of_yojson value
               |> Result.map (fun expected -> keeper_name, runtime_id, expected))))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

let runtime_config_path_error_status message =
  if String.equal message Runtime.runtime_config_path_missing_message
  then `Not_found
  else `Internal_server_error

type runtime_config_write_operation =
  | Runtime_config_raw_save
  | Runtime_config_routing of runtime_route_lane * string option
  | Runtime_config_routing_list of runtime_route_lane * string list
  | Runtime_config_assignment of string * string option

let runtime_config_write_operation_details = function
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

let runtime_config_write_operation_label = function
  | Runtime_config_raw_save -> "raw_save"
  | Runtime_config_routing _ | Runtime_config_routing_list _ -> "routing"
  | Runtime_config_assignment _ -> "assignment"
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
               | Some commit -> [ "commit", runtime_config_commit_json commit ])
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

let audit_skill_write state agent_name ~reference ~source_text ~status ~outcome =
  try
    Audit_log.log_action
      (Mcp_server.workspace_config state)
      ~agent_id:agent_name
      ~action:(Audit_log.Custom "skill_write")
      ~details:
        (`Assoc
          [ "reference", Skill_reference.to_yojson reference
          ; "candidate_revision",
            `String
              (Skill_reference.content_revision_of_source_text source_text
               |> Skill_reference.content_revision_to_string)
          ; "bytes", `Int (String.length source_text)
          ; "lines", `Int (runtime_config_line_count source_text)
          ; "status", `String status
          ])
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Dashboard.warn "Skill write audit failed: %s" (Printexc.to_string exn)
;;

let audit_skill_delete state agent_name ~reference ~status ~recovery ~outcome =
  try
    Audit_log.log_action
      (Mcp_server.workspace_config state)
      ~agent_id:agent_name
      ~action:(Audit_log.Custom "skill_delete")
      ~details:
        (`Assoc
          ([ "reference", Skill_reference.to_yojson reference
           ; "status", `String status
           ]
           @ match recovery with
             | None -> []
             | Some (recovery_id, disposition) ->
               [ "recovery_id", `String recovery_id
               ; "recovery_disposition", `String disposition
               ]))
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Dashboard.warn "Skill delete audit failed: %s" (Printexc.to_string exn)
;;

let skill_error_recovery error =
  Server_skill_editor.error_recovery error
  |> Option.map (fun (recovery_id, disposition) ->
    ( recovery_id
    , Server_skill_editor.recovery_disposition_to_string disposition ))
;;

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

let handle_runtime_assignment_post_with ~set_assignment state agent_name req reqd
    body_str =
  match parse_runtime_assignment_body body_str with
  | Error msg ->
    respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
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
       respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
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

type gate_mode_recovery =
  | Recovery_completed of Keeper_gate.operator_recovery_report
  | Recovery_failed of string
  | Recovery_not_requested

let gate_mode_change_json change recovery =
  let recovery_status, recovery_error, started, queued, recovery_failures =
    match recovery with
    | Recovery_completed report ->
      ( (if report.failures = [] then "completed" else "partial")
      , `Null
      , List.length report.started_ids
      , report.queued
      , report.failures )
    | Recovery_failed detail -> "failed", `String detail, 0, 0, []
    | Recovery_not_requested -> "not_requested", `Null, 0, 0, []
  in
  let recovery_failures_json =
    `List
      (List.map
         (fun (failure : Keeper_gate.auto_judge_owner_failure) ->
            `Assoc
              [ "keeper_name", `String failure.keeper_name
              ; ( "approval_id"
                , match failure.approval_id with
                  | Some approval_id -> `String approval_id
                  | None -> `Null )
              ; "operator_detail", `String failure.operator_detail
              ])
         recovery_failures)
  in
  let `Assoc fields = Keeper_gate_mode.change_json change in
  `Assoc
    (("recovery_status", `String recovery_status)
     :: ("recovery_error", recovery_error)
     :: ("started", `Int started)
     :: ("queued", `Int queued)
     :: ("recovery_failure_count", `Int (List.length recovery_failures))
     :: ("recovery_failures", recovery_failures_json)
     :: fields)
;;

module For_testing = struct
  type nonrec gate_mode_recovery = gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  let gate_mode_change_json = gate_mode_change_json
  let exact_lane_run_permission = exact_lane_run_permission
  let runtime_probe_read_permission = runtime_probe_read_permission
  let handle_runtime_assignment_post = handle_runtime_assignment_post
  let handle_runtime_assignment_post_with = handle_runtime_assignment_post_with
  let fusion_run_detail_response = fusion_run_detail_response
  let fusion_run_list_response = fusion_run_list_response
end

(* One keeper held to a higher bar than the workspace. Its own handler
   rather than a field on the workspace one: the two answer different
   questions, and a body that omitted [keeper_name] would otherwise move
   every keeper at once. *)
(* Which admitted slot this Keeper uses first in one exact-output lane. Naming
   a slot the lane does not offer is refused here rather than on the next run,
   so the operator learns while still looking at the setting. *)
let handle_keeper_exact_lane_body state operator_name request reqd body_str =
  let refuse message =
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (operator_error_json message)
  in
  try
    let fields =
      match Yojson.Safe.from_string body_str with
      | `Assoc fields -> fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        []
    in
    match List.assoc_opt "keeper_name" fields, List.assoc_opt "lane_id" fields with
    | ( Some (`String keeper_name)
      , Some (`String lane_id) )
      when String.trim keeper_name <> "" && String.trim lane_id <> "" -> (
      match
        match List.assoc_opt "slot_id" fields with
        | None | Some `Null -> Ok None
        | Some (`String slot_id) when String.trim slot_id <> "" ->
          Ok (Some (String.trim slot_id))
        | Some _ -> Error "slot_id must be a non-empty string or null"
      with
      | Error message -> refuse message
      | Ok slot_id -> (
        let config = Mcp_server.workspace_config state in
        let set () =
          Keeper_exact_lane_preference.set
            config ~actor:operator_name ~keeper_name ~lane_id slot_id
        in
        match
          match slot_id with
          | None -> set ()
          | Some slot_id ->
            Result.bind
              (Keeper_exact_lane_preference.validate_admitted_slot
                 ~lane_id
                 ~slot_id)
              set
        with
        | Error message -> refuse message
        | Ok current ->
          Dashboard_cache.invalidate_prefix
            (Printf.sprintf "gate:%s;" config.base_path);
          Sse.broadcast
            (`Assoc
               [ "type", `String "keeper_exact_lane_preference_changed"
               ; "keeper_name", `String keeper_name
               ; "lane_id", `String lane_id
               ; ( "slot_id"
                 , match slot_id with
                   | Some slot_id -> `String slot_id
                   | None -> `Null )
               ]);
          respond_json_value_with_cors request reqd
            (`Assoc
               [ "ok", `Bool true
               ; "keeper_name", `String keeper_name
               ; "lane_id", `String lane_id
               ; ( "slot_id"
                 , match current with
                   | Some current ->
                     `String current.Keeper_exact_lane_preference.slot_id
                   | None -> `Null )
               ])))
    | _, _ -> refuse "keeper_name and lane_id are required"
  with Yojson.Json_error message -> refuse message
;;

let handle_gate_keeper_mode_body state operator_name request reqd body_str =
  let refuse message =
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (operator_error_json message)
  in
  try
    let fields =
      match Yojson.Safe.from_string body_str with
      | `Assoc fields -> fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        []
    in
    match List.assoc_opt "keeper_name" fields with
    | Some (`String keeper_name) when String.trim keeper_name <> "" -> (
      (* An absent mode clears the override; a present one has to parse.
         Absent and unreadable are different answers and only one of them is
         a request to stop singling this keeper out. *)
      match
        match List.assoc_opt "mode" fields with
        | None | Some `Null -> Ok None
        | Some mode_json ->
          Result.map Option.some (Keeper_gate_mode.parse_json mode_json)
      with
      | Error message -> refuse message
      | Ok mode -> (
        (* Same admission bar as the workspace lane: an auto_judge override
           is a promise that a judge topology exists to drain it, and this
           route is the entry point of the override-only-auto_judge state
           the sweeps now serve. *)
        let readiness =
          match mode with
          | Some Keeper_gate_mode.Auto_judge ->
            Hitl_summary_worker.snapshot_topology_readiness ()
          | Some (Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow)
          | None -> Ok ()
        in
        match readiness with
        | Error detail ->
          respond_json_value_with_cors
            ~status:`Service_unavailable
            request
            reqd
            (operator_error_json ("Auto Judge unavailable: " ^ detail))
        | Ok () -> (
        let config = Mcp_server.workspace_config state in
        match
          Keeper_gate_mode.set_for_keeper config ~actor:operator_name
            ~keeper_name mode
        with
        | Error message -> refuse message
        | Ok change ->
          Dashboard_cache.invalidate_prefix
            (Printf.sprintf "gate:%s;" config.base_path);
          Sse.broadcast
            (`Assoc
               [ "type", `String "gate_keeper_mode_changed"
               ; "keeper_name", `String keeper_name
               ; ( "mode"
                 , match mode with
                   | Some mode -> `String (Keeper_gate_mode.to_string mode)
                   | None -> `Null )
               ]);
          respond_json_value_with_cors request reqd
            (match Keeper_gate_mode.keeper_change_json change with
             | `Assoc fields -> `Assoc fields))))
    | Some _ | None -> refuse "keeper_name is required"
  with Yojson.Json_error message -> refuse message
;;


let handle_gate_mode_body_for_lane
      ~set_mode
      ~sse_type
      state
      operator_name
      request
      reqd
      body_str
  =
  try
    let args = Yojson.Safe.from_string body_str in
    let mode_json =
      match args with
      | `Assoc fields -> List.assoc_opt "mode" fields
      | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
        None
    in
    match mode_json with
    | None ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json "mode is required")
    | Some mode_json ->
      (match Keeper_gate_mode.parse_json mode_json with
       | Error message ->
         respond_json_value_with_cors
           ~status:`Bad_request
           request
           reqd
           (operator_error_json message)
       | Ok mode ->
         let config = Mcp_server.workspace_config state in
         let readiness =
           match mode with
           | Keeper_gate_mode.Auto_judge ->
             Hitl_summary_worker.snapshot_topology_readiness ()
           | Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow -> Ok ()
         in
         (match readiness with
          | Error detail ->
            respond_json_value_with_cors
              ~status:`Service_unavailable
              request
              reqd
              (operator_error_json ("Auto Judge unavailable: " ^ detail))
          | Ok () ->
         (match set_mode config ~actor:operator_name mode with
          | Error message ->
            respond_json_value_with_cors
              ~status:`Bad_request
              request
              reqd
              (operator_error_json message)
          | Ok (change : Keeper_gate_mode.change) ->
            Dashboard_cache.invalidate_prefix
              (Printf.sprintf "gate:%s;" config.base_path);
            Sse.broadcast
              (`Assoc
                 [ "type", `String sse_type
                 ; "mode", `String (Keeper_gate_mode.to_string mode)
                 ; ( "previous_mode"
                   , match change.previous with
                     | Some previous -> `String (Keeper_gate_mode.to_string previous)
                     | None -> `Null )
                 ; "actor", `String operator_name
                 ; "changed_at", `String change.changed_at
                 ]);
            let recovery =
              match mode with
              | Keeper_gate_mode.Auto_judge ->
                (match
                   Keeper_gate.request_operator_auto_judge_recovery
                     ~base_path:config.base_path
                 with
                 | Ok report -> Recovery_completed report
                 | Error detail ->
                   Log.Dashboard.emit
                     Log.Warn
                     ~details:
                       (`Assoc
                          [ "event", `String "gate_mode_recovery_failed"
                          ; "base_path", `String config.base_path
                          ; "actor", `String operator_name
                          ; "mode", `String (Keeper_gate_mode.to_string mode)
                          ; "changed_at", `String change.changed_at
                          ; "error", `String detail
                          ])
                     "Gate mode was saved, but Auto Judge recovery failed";
                   Recovery_failed detail)
              | Keeper_gate_mode.Manual | Keeper_gate_mode.Always_allow ->
                Recovery_not_requested
            in
            respond_json_value_with_cors
              request
              reqd
              (gate_mode_change_json change recovery))))
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_mode_body state operator_name request reqd body_str =
  handle_gate_mode_body_for_lane
    ~set_mode:Keeper_gate_mode.set
    ~sse_type:"gate_mode_changed"
    state
    operator_name
    request
    reqd
    body_str
;;

let handle_gate_external_mode_body state operator_name request reqd body_str =
  handle_gate_mode_body_for_lane
    ~set_mode:Keeper_gate_mode.set_external
    ~sse_type:"gate_external_mode_changed"
    state
    operator_name
    request
    reqd
    body_str
;;

let handle_gate_resolve_body state operator_name request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let base_path = (Mcp_server.workspace_config state).Workspace.base_path in
    match dashboard_gate_resolve_http_json ~base_path ~created_by:operator_name ~args with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error (Gone _ as error) ->
      respond_json_value_with_cors
        ~status:`Not_found
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
    | Error (Unavailable _ as error) ->
      respond_json_value_with_cors
        ~status:`Service_unavailable
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
    | Error (Bad_request _ as error) ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json (approval_resolve_http_error_to_string error))
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_retry_body state operator_name request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let base_path = (Mcp_server.workspace_config state).base_path in
    match dashboard_gate_retry_http_json ~base_path ~requested_by:operator_name ~args with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error message ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json message)
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let handle_gate_rule_delete_body state request reqd body_str =
  try
    let args = Yojson.Safe.from_string body_str in
    let base_path = (Mcp_server.workspace_config state).base_path in
    match dashboard_gate_rule_delete_http_json ~base_path ~args with
    | Ok json -> respond_json_value_with_cors request reqd json
    | Error message ->
      respond_json_value_with_cors
        ~status:`Bad_request
        request
        reqd
        (operator_error_json message)
  with
  | Yojson.Json_error message ->
    respond_json_value_with_cors
      ~status:`Bad_request
      request
      reqd
      (operator_error_json (Printf.sprintf "invalid json: %s" message))
;;

let add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_token_permission_auth ~permission:Masc_domain.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           handle_broadcast state agent_name reqd body_str
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_token_permission_auth ~permission:Masc_domain.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           handle_broadcast state agent_name reqd body_str
         )
       ) request reqd)
  |> Http.Router.prefix_get
       "/api/dashboard/execute-output/"
       (handle_execute_output_stream ~sw ~clock)
  |> Http.Router.prefix_get
       "/api/v1/dashboard/execute-output/"
       (handle_execute_output_stream ~sw ~clock)

  (* Batch dashboard endpoint: single request replaces 4 separate API calls *)
  |> Http.Router.get "/api/v1/dashboard" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           `Assoc
             [
               ("error", `String "dashboard batch contract removed");
               ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
             ]
         in
         Http.Response.json_value ~status:`Gone ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/shell" (fun request reqd ->
       with_public_read (fun state req reqd ->
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
       ) request reqd)
  (* RFC-0266 §7 Phase 4: read-only snapshot of the in-memory fusion run registry
     (in-progress + recently completed). The fusion panel fetches this on load and
     re-fetches on the [fusion_run_status] SSE event. Registry reads are O(runs)
     in-memory, so no Dashboard_cache layer; each run serializes through the shared
     Fusion_run_registry.run_to_yojson so the shape matches the SSE delta. *)
  |> Http.Router.get "/api/v1/dashboard/fusion-runs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           fusion_run_list_response ~registry:(Fusion_run_registry.global ())
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.prefix_get
       Server_dashboard_fusion_run_projection.detail_prefix
       (fun request reqd ->
       with_public_read (fun _state req reqd ->
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
       ) request reqd)
  (* RFC-0361 D4: read-only snapshot of the completion-authority review registry
     (in-progress + recently completed). Sibling of the fusion route above and
     shaped identically; each run serializes through the shared
     Verification_run_registry.run_to_yojson so the panel and any later SSE delta
     read one shape. Registry reads are O(runs) in-memory, so no Dashboard_cache
     layer. *)
  |> Http.Router.get "/api/v1/dashboard/verification-runs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
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
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goal-verification-runs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
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
                      Goal_verification_run_registry.run_to_yojson
                      runs) )
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  (* One bounded, read-only join of lane admission and retained observations.
     Unlike the paged run endpoint below this always names every standalone
     lanes, including configured lanes with no currently retained run. *)
  |> Http.Router.get "/api/v1/dashboard/standalone-lanes" (fun request reqd ->
       with_token_permission_auth ~permission:exact_lane_run_permission
         (fun _state _agent_name req reqd ->
            Http.Response.json_value
              ~compress:true
              ~request:req
              (Server_standalone_lane_projection.snapshot_json ())
              reqd)
         request
         reqd)
  (* Paged, and without detail payloads. [lane=] filters BEFORE pagination so
     the Verifier's task/Goal review registries cannot be hidden behind a busy
     Librarian window. Serving every exact-output payload made this response
     246 MB for 5,908 runs; [exact-lane-runs/<run_id>] carries the exact prompt
     or retained review/tool evidence for the one run an operator opened. *)
  |> Http.Router.get "/api/v1/dashboard/exact-lane-runs" (fun request reqd ->
       with_token_permission_auth ~permission:exact_lane_run_permission
         (fun _state _agent_name req reqd ->
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
         match before with
         | Error message -> respond_dashboard_error ~request:req reqd message
         | Ok before ->
           (match
              Server_standalone_lane_projection.recent_run_page_json
                ~limit ~before ~lane
            with
            | Error message ->
              respond_dashboard_error ~request:req reqd message
            | Ok json ->
              Http.Response.json_value ~compress:true ~request:req json reqd)
       ) request reqd)
  |> Http.Router.prefix_get "/api/v1/dashboard/exact-lane-runs/" (fun request reqd ->
       with_token_permission_auth ~permission:exact_lane_run_permission
         (fun _state _agent_name req reqd ->
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
         then respond_dashboard_error ~request:req reqd "run_id is required"
         else (
           match Server_standalone_lane_projection.run_detail_json ~run_id with
           | Server_standalone_lane_projection.Detail_not_found ->
             respond_dashboard_error
               ~status:`Not_found
               ~request:req
               reqd
               ("no retained standalone lane run named " ^ run_id)
           | Server_standalone_lane_projection.Detail_ambiguous ->
             respond_dashboard_error
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
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/workspace" (fun request reqd ->
       with_public_read handle_dashboard_workspace request reqd)
  (* Dev-only bearer for the dashboard UI, minted at the role named by
     [Server_routes_http_dashboard_dev_token.dashboard_dev_role]. Served
     exclusively when the server binds to loopback and strict-auth env
     overrides are disabled, so that a LAN deployment never hands out a
     credential over the wire. The token is canonicalized to the [dashboard]
     actor and persisted at [.masc/auth/dashboard.token]. *)
  |> Http.Router.get "/api/v1/dashboard/dev-token" (fun request reqd ->
       if (not (http_auth_bind_is_loopback ()))
          || http_auth_strict_enabled () then
         respond_dashboard_error ~status:`Not_found ~request reqd
           "dev-token endpoint disabled (non-loopback bind or strict auth)"
       else
         with_public_read (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let raw_result =
             Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token_for_authority
               ~request_authority:(Server_request_authority.current_exn ())
               ~base_path
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
  |> Http.Router.get "/api/v1/dashboard/runtime-probe" (fun request reqd ->
       let force = Server_utils.bool_query_param request "force" ~default:false in
       let handle _state req reqd =
         let json = dashboard_runtime_probe_http_json ~force () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       in
       with_permission_auth ~permission:runtime_probe_read_permission handle request reqd)
  |> Http.Router.get "/api/v1/dashboard/runtime-defaults" (fun request reqd ->
       (* Structured, already-resolved runtime defaults / model routing for the
          Settings surface. Read-only projection of the runtime.toml SSOT
          singletons (no credentials, no raw TOML), so a public read mirrors the
          other dashboard read surfaces. *)
       with_public_read (fun _state req reqd ->
         let json =
           Server_dashboard_runtime_defaults_json.current
             ~generated_at_iso:(Masc_domain.now_iso ()) ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
         request reqd)
  |> Http.Router.get "/api/v1/runtime/resolved" (fun request reqd ->
       (* Single resolved-runtime document (bugs #14/#15/#36): effective
          max-context + source per runtime, configured lanes, and the full
          keeper fleet joined against [runtime.assignments] with the
          [runtime].default rider made explicit. Read-only projection, same
          public-read posture as /api/v1/dashboard/runtime-defaults. *)
       with_public_read (fun state req reqd ->
         let json =
           Server_dashboard_runtime_resolved_json.build
             ~generated_at_iso:(Masc_domain.now_iso ())
             ~config:(Mcp_server.workspace_config state)
         in
         Http.Response.json_value ~compress:true ~request:req json reqd)
         request reqd)
  |> Http.Router.get "/api/v1/runtime/sessions/official-client" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
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
         request reqd)
  |> Http.Router.post "/api/v1/runtime/official-client/probe" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             let base_path = (Mcp_server.workspace_config state).base_path in
             respond_official_client_probe_result
               req
               reqd
               (Official_client_probe.probe_body ~base_path ~body)))
         request reqd)
  |> Http.Router.post "/api/v1/runtime/sessions/official-client/resolve" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             respond_official_client_session_result
               req
               reqd
               (Official_client_session.resolve_body
                  ~config:(Mcp_server.workspace_config state)
                  ~actor:agent_name
                  ~body)))
         request reqd)
  |> Http.Router.get "/api/v1/skills/editor/sources" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           match
             Server_skill_editor.writable_sources
               ~base_path:(Mcp_server.workspace_config state).base_path
           with
           | Error error -> respond_skill_editor_error ~request:req reqd error
           | Ok sources ->
             Http.Response.json_value
               ~compress:true
               ~request:req
               (`Assoc
                 [ "status", `String "ready"
                 ; ( "sources"
                   , `List
                       (List.map Server_skill_editor.writable_source_to_yojson sources) )
                 ])
               reqd)
         request reqd)
  |> Http.Router.post "/api/v1/skills/evidence" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = _; confirmed = _ } ->
               Http.Response.json_value
                 ~compress:true
                 ~request:req
                 (Server_skill_evidence.project
                    ~config:(Mcp_server.workspace_config state)
                    reference)
                 reqd))
         request reqd)
  |> Http.Router.get "/api/v1/async-requests" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Response.json_value
             ~compress:true
             ~request:req
             (Server_async_request_observability.project
                ~base_path:(Mcp_server.workspace_config state).base_path)
             reqd)
         request reqd)
  |> Http.Router.post "/api/v1/skills/editor/create" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_create_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok { source_id; package_id; source_text } ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let refresh () =
                 match Runtime.load_config_observation () with
                 | Error message -> Error message
                 | Ok observation ->
                   Server_skill_snapshot_runtime.refresh_from_observation
                     ~base_path
                     observation
                   |> Result.map_error Server_skill_snapshot_runtime.error_to_string
               in
               (match
                  Server_skill_editor.create
                    ~base_path
                    ~source_id
                    ~package_id
                    ~source_text
                    ~refresh
                with
                | Error error -> respond_skill_editor_error ~request:req reqd error
                | Ok outcome ->
                  let preview, status, audit_outcome =
                    match outcome with
                    | Server_skill_editor.Created_and_published
                        { preview; snapshot_revision = _ } ->
                      preview, "created_and_published", Audit_log.Success
                    | Created_but_unpublished { preview; reason } ->
                      preview, "created_but_unpublished", Audit_log.Failure reason
                  in
                  audit_skill_write
                    state
                    agent_name
                    ~reference:preview.profile.reference
                    ~source_text
                    ~status
                    ~outcome:audit_outcome;
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (Server_skill_editor.create_outcome_to_yojson outcome)
                    reqd)))
         request reqd)
  |> Http.Router.add
       ~path:"/api/v1/skills/editor"
       ~methods:[ `DELETE ]
       ~handler:(fun request reqd ->
         with_token_permission_auth ~permission:Masc_domain.CanAdmin
           (fun state agent_name req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               match parse_skill_editor_body body_str with
               | Error message ->
                 respond_dashboard_error ~status:`Bad_request ~request:req reqd message
               | Ok { reference; source_text = _; confirmed } ->
                 let base_path = (Mcp_server.workspace_config state).base_path in
                 let refresh () =
                   match Runtime.load_config_observation () with
                   | Error message -> Error message
                   | Ok observation ->
                     Server_skill_snapshot_runtime.refresh_from_observation
                       ~base_path
                       observation
                     |> Result.map_error Server_skill_snapshot_runtime.error_to_string
                 in
                 let result =
                   Server_skill_editor.delete
                     ~base_path
                     ~reference
                     ~confirmed:(Option.value confirmed ~default:false)
                     ~refresh
                 in
                 Eio.Cancel.protect (fun () ->
                  match result with
                  | Error error ->
                    audit_skill_delete state agent_name ~reference
                      ~status:(Server_skill_editor.error_code error)
                      ~recovery:(skill_error_recovery error)
                      ~outcome:
                        (Audit_log.Failure (Server_skill_editor.error_to_string error));
                    respond_skill_editor_error ~request:req reqd error
                  | Ok outcome ->
                    let status, audit_outcome, recovery_id, disposition =
                      match outcome with
                      | Server_skill_editor.Deleted_and_published
                          { recovery_id; disposition; _ } ->
                        ( "deleted_and_published"
                        , Audit_log.Success
                        , recovery_id
                        , disposition )
                      | Deleted_but_unpublished
                          { reason; recovery_id; disposition; _ } ->
                        ( "deleted_but_unpublished"
                        , Audit_log.Failure
                            (Server_skill_editor.delete_unpublished_reason_to_string
                               reason)
                        , recovery_id
                        , disposition )
                    in
                    audit_skill_delete state agent_name ~reference ~status
                      ~recovery:
                        (Some
                           ( recovery_id
                           , Server_skill_editor.recovery_disposition_to_string
                               disposition ))
                      ~outcome:audit_outcome;
                    Http.Response.json_value
                      ~compress:true
                      ~request:req
                      (Server_skill_editor.delete_outcome_to_yojson outcome)
                      reqd))
             )
           request reqd)
  |> Http.Router.post "/api/v1/skills/editor/read" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = _; confirmed = _ } ->
               (match
                  Server_skill_editor.load
                    ~base_path:(Mcp_server.workspace_config state).base_path
                    reference
                with
                | Ok loaded ->
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (Server_skill_editor.loaded_to_yojson loaded)
                    reqd
                | Error error -> respond_skill_editor_error ~request:req reqd error)))
         request reqd)
  |> Http.Router.post "/api/v1/skills/editor/preview" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = None; confirmed = _ } ->
               respond_dashboard_error
                 ~status:`Bad_request
                 ~request:req
                 reqd
                 "source_text required"
             | Ok { reference; source_text = Some source_text; confirmed = _ } ->
               (match
                  Server_skill_editor.preview
                    ~base_path:(Mcp_server.workspace_config state).base_path
                    reference
                    ~source_text
                with
                | Ok preview ->
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (`Assoc
                      [ "ok", `Bool true
                      ; "status", `String "valid"
                      ; "preview", Server_skill_editor.preview_to_yojson preview
                      ])
                    reqd
                | Error error -> respond_skill_editor_error ~request:req reqd error)))
         request reqd)
  |> Http.Router.post "/api/v1/skills/editor/save" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_skill_editor_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok { reference; source_text = None; confirmed = _ } ->
               respond_dashboard_error
                 ~status:`Bad_request
                 ~request:req
                 reqd
                 "source_text required"
             | Ok { reference; source_text = Some source_text; confirmed = _ } ->
               let base_path = (Mcp_server.workspace_config state).base_path in
               let refresh () =
                 match Runtime.load_config_observation () with
                 | Error message -> Error message
                 | Ok observation ->
                   Server_skill_snapshot_runtime.refresh_from_observation
                     ~base_path
                     observation
                   |> Result.map_error Server_skill_snapshot_runtime.error_to_string
               in
               (match
                  Server_skill_editor.save
                    ~base_path
                    ~reference
                    ~source_text
                    ~refresh
                with
                | Error error ->
                  audit_skill_write state agent_name ~reference ~source_text
                    ~status:(Server_skill_editor.error_code error)
                    ~outcome:(Audit_log.Failure (Server_skill_editor.error_to_string error));
                  respond_skill_editor_error ~request:req reqd error
                | Ok outcome ->
                  let status, audit_outcome =
                    match outcome with
                    | Server_skill_editor.Unchanged _ ->
                      "unchanged", Audit_log.Success
                    | Saved_and_published _ ->
                      "saved_and_published", Audit_log.Success
                    | Saved_but_unpublished { reason; _ } ->
                      "saved_but_unpublished", Audit_log.Failure reason
                  in
                  audit_skill_write state agent_name ~reference ~source_text
                    ~status
                    ~outcome:audit_outcome;
                  Http.Response.json_value
                    ~compress:true
                    ~request:req
                    (Server_skill_editor.save_outcome_to_yojson outcome)
                    reqd)))
         request reqd)
  |> Http.Router.get "/api/v1/runtime/config/raw" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
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
             respond_dashboard_error
               ~status:(runtime_config_path_error_status msg)
               ~request:req reqd msg)
         request reqd)
  (* RFC-0306 §3.1 — typed read of the active fusion config for the settings
     editor. [Fusion_config_loader.load] returns [Ok disabled] when runtime.toml
     or its [fusion] section is absent, and [Error] only when an existing section
     fails to parse/validate (a broken on-disk config), which surfaces as 500. *)
  |> Http.Router.get "/api/v1/runtime/config/fusion" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           match Fusion_config_loader.load ~base_path with
           | Ok config ->
             Http.Response.json_value ~compress:true ~request:req
               (`Assoc
                 [ ("generated_at", `String (Masc_domain.now_iso ()))
                 ; ("config", Fusion_config_json.to_yojson config)
                 ])
               reqd
           | Error msg ->
             respond_dashboard_error ~status:`Internal_server_error
               ~request:req reqd msg)
         request reqd)
  |> Http.Router.post "/api/v1/runtime/config/raw/preview" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_config_raw_body body_str with
             | Error msg ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
             | Ok source_text ->
               (match Keeper_runtime_config.validate_source_text source_text with
                | Error msg ->
                  respond_dashboard_error
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
         request reqd)
  |> Http.Router.post "/api/v1/runtime/config/raw" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_config_raw_body body_str with
             | Error msg ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
             | Ok source_text ->
               (* RFC-0273 §3.3 — record the runtime.toml write to the audit
                  audit trail (actor + path + size) on top of the CanAdmin gate.
                  The config body is deliberately excluded: runtime.toml can carry
                  provider secrets (RFC-0132 redaction). *)
               (match Keeper_runtime_config.validate_source_text source_text with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:Runtime_config_raw_save ~text:source_text
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error
                    ~status:`Bad_request
                    ~request:req
                    reqd
                    ("runtime config parse failed: " ^ msg)
                | Ok report
                  when not (Keeper_runtime_config.validation_report_is_valid report) ->
                  let detail = keeper_validation_error_message report in
                  audit_runtime_config_write state agent_name
                    ~operation:Runtime_config_raw_save ~text:source_text
                    ~outcome:(Audit_log.Failure detail) ();
                  respond_keeper_validation_error ~request:req reqd report
                | Ok _ ->
                  (match Runtime.save_config_text source_text with
                   | Error msg ->
                     audit_runtime_config_write state agent_name
                       ~operation:Runtime_config_raw_save ~text:source_text
                       ~outcome:(Audit_log.Failure msg) ();
                     respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                   | Ok receipt ->
                     respond_runtime_config_commit state agent_name
                       ~operation:Runtime_config_raw_save ~receipt req reqd))
           )
         ) request reqd)
  |> Http.Router.post "/api/v1/runtime/config/routing" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_route_body body_str with
             | Error msg ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
             | Ok (Runtime_route_runtime_id (Runtime_default, Some runtime_id)) ->
               (match Runtime.set_runtime_default ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok receipt ->
                  respond_runtime_config_commit state agent_name
                    ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
                    ~receipt req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_default, None)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 "default runtime_id required"
             | Ok (Runtime_route_runtime_id (Runtime_media_failover, _)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 "media_failover runtime_ids required"
             | Ok (Runtime_route_runtime_ids (Runtime_media_failover, runtime_ids)) ->
               (match Runtime.set_runtime_media_failover ~runtime_ids () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok receipt ->
                  respond_runtime_config_commit state agent_name
                    ~operation:
                      (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
                    ~receipt req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_named_lane lane_id, _)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 (Printf.sprintf "%s runtime_ids required" lane_id)
             | Ok (Runtime_route_runtime_ids (Runtime_named_lane lane_id, runtime_ids))
               ->
               (match Runtime.set_runtime_lane_candidates ~lane_id ~runtime_ids () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing_list
                         (Runtime_named_lane lane_id, runtime_ids))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok receipt ->
                  respond_runtime_config_commit state agent_name
                    ~operation:
                      (Runtime_config_routing_list
                         (Runtime_named_lane lane_id, runtime_ids))
                    ~receipt req reqd)
             | Ok (Runtime_route_runtime_ids (lane, _)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 (Printf.sprintf
                    "%s runtime_id required"
                    (runtime_route_lane_to_string lane))
           )
         ) request reqd)
  |> Http.Router.post "/api/v1/runtime/config/assignment" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_runtime_assignment_post state agent_name req reqd body_str
           )
         ) request reqd)
  (* Phase 1 Action 2 — live Dashboard_cache state surface.  Renders
     hit_ratio, in-flight compute count, per-entry ttl_remaining, and
     timeout-circuit-open counts so operators can correlate slow endpoints
     (Server-Timing header) with cache contention without external telemetry.
     Read-only; no env tuning side-effect. *)
  |> Http.Router.get "/api/v1/dashboard/cache-stats" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cache.stats () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/logs" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:200
           |> max 1 |> min 3000
         in
         let level_filter =
           match Server_utils.query_param req "level" with
           | Some v -> v
           | None -> "DEBUG"
         in
         match Log.level_of_string_opt level_filter with
         | None ->
           let json =
             `Assoc
               [ "error", `String "invalid_log_level"
               ; "message", `String "level must be one of debug, info, warn, warning, error"
               ; "level", `String level_filter
               ]
           in
           Http.Response.json_value ~status:`Bad_request ~compress:true ~request:req json reqd
         | Some applied_level ->
           let min_level = Log.level_to_int applied_level in
           let since_seq =
             match Server_utils.query_param req "since_seq" with
             | None -> None
             | Some _ ->
                 let seq = Server_utils.int_query_param req "since_seq" ~default:(-1) in
                 if seq < 0 then None else Some seq
           in
           let before_seq =
             match Server_utils.query_param req "before_seq" with
             | None -> None
             | Some _ ->
                 let seq = Server_utils.int_query_param req "before_seq" ~default:(-1) in
                 if seq < 0 then None else Some seq
           in
           let module_filter = match Server_utils.query_param req "module" with
             | Some v -> v
             | None -> ""
           in
           let category_filter = Server_utils.query_param req "category" in
           let exclude_category =
             match Server_utils.query_param req "exclude_category" with
             | None -> None
             | Some raw ->
                 let parts = String.split_on_char ',' raw in
                 let trimmed = List.map String.trim parts in
                 let non_empty = List.filter (fun s -> s <> "") trimmed in
                 match non_empty with
                 | [] -> None
                 | xs -> Some xs
           in
           let entries =
             Log.Ring.recent ~limit ~min_level ~module_filter ?since_seq
               ?before_seq ?category_filter ?exclude_category ()
           in
           (* Bounds read after the slice: seqs are monotonic, so the
              window can only have grown — never claims more history
              than the slice actually had available. *)
           let ring_bounds = Log.Ring.bounds () in
           let json =
             dashboard_logs_json ~config:(Mcp_server.workspace_config state) ~limit
               ~level_filter ~applied_level ~min_level ~module_filter ~since_seq
               ~before_seq ~category_filter ~exclude_category ~ring_bounds entries
           in
           Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/provider-logs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "provider_logs" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:live_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Provider_logs.dashboard_provider_logs_json ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/provider-logs/tail" (fun request reqd ->
         with_public_read (fun _state req reqd ->
         let status, json = Provider_logs.dashboard_provider_log_tail_json req in
         Http.Response.json_value ~status ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/logs/tool-host-failures" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_broadcast" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
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
                 report;
               respond_dashboard_ok ~request:req reqd
           | Error message ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [ ("ok", `Bool false); ("error", `String message) ])
                 reqd)
       ) request reqd)
  (* RFC-0049 — surface/section open counters. Aggregate Otel_metric_store
     counters only; the request body is discarded after increment. *)
  |> Http.Router.post "/api/v1/dashboard/nav-event" (fun request reqd ->
       with_public_read (fun _state req reqd ->
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
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "config_introspect" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:config_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Env_config_introspect.to_json ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/project-snapshot" (fun request reqd ->
       with_public_read (fun state req reqd ->
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
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         (* The default execution surface is a large proactive cached snapshot.
            Re-compressing it on every dashboard poll burns the same serving
            domain that accepts health/chat/keeper requests; serve identity JSON
            here and keep the compute/cache policy in
            [dashboard_execution_http_json]. *)
         match dashboard_execution_cached_http_body ~state request with
         | Some body -> Http.Response.json ~compress:false ~request:req body reqd
         | None ->
           let json = dashboard_execution_http_json ~state ~sw ~clock request in
           Http.Response.json_value ~compress:false ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution-trust" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_execution_trust_http_json ~state ~sw ~clock request
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/board" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_memory_http_json ~config:(Mcp_server.workspace_config state) req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/link-previews" (fun request reqd ->
       with_permission_auth ~permission:Masc_domain.CanReadState
         (fun state req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_dashboard_link_previews state req reqd body_str))
         request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-memory-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let cache_key = Printf.sprintf "keeper_memory_health:%s" base_path in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json
                 ~base_path))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/runtime-observables" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           Server_dashboard_http_runtime_observables.runtime_observables_http_json ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/gate" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = dashboard_gate_http_json req ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/gate/tool-events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = dashboard_gate_tool_events_http_json req ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/mode" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_mode_body state operator_name request reqd))
         request reqd)
  (* The same two lists the Gate projection carries, on their own so a surface
     that only wants them does not pay for the approval queue and the resolved
     history to find out which Keepers were singled out. *)
  |> Http.Router.get "/api/v1/dashboard/gate/keeper-settings" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let modes, modes_state =
           match Keeper_gate_mode.keeper_overrides ~base_path with
           | Ok rows ->
             ( `List
                 (List.map
                    (fun (row : Keeper_gate_mode.keeper_override) ->
                      `Assoc
                        [ "keeper_name", `String row.keeper_name
                        ; "mode", `String (Keeper_gate_mode.to_string row.mode)
                        ])
                    rows)
             , `Assoc [ "state", `String "ready" ] )
           | Error detail ->
             ( `List []
             , `Assoc [ "state", `String "unavailable"; "error", `String detail ] )
         in
         let exact_lanes, exact_lanes_state =
           match Keeper_exact_lane_preference.all ~base_path with
           | Ok rows ->
             ( `List
                 (List.map
                    (fun (row : Keeper_exact_lane_preference.t) ->
                      `Assoc
                        [ "keeper_name", `String row.keeper_name
                        ; "lane_id", `String row.lane_id
                        ; "slot_id", `String row.slot_id
                        ])
                    rows)
             , `Assoc [ "state", `String "ready" ] )
           | Error detail ->
             ( `List []
             , `Assoc [ "state", `String "unavailable"; "error", `String detail ] )
         in
         Http.Response.json_value ~compress:true ~request:req
           (`Assoc
              [ "modes", modes
              ; "modes_state", modes_state
              ; "exact_lanes", exact_lanes
              ; "exact_lanes_state", exact_lanes_state
              ])
           reqd)
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/keeper-mode" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_keeper_mode_body state operator_name request reqd))
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/runtime/keeper-exact-lane" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_keeper_exact_lane_body state operator_name request reqd))
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/external-mode" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_external_mode_body state operator_name request reqd))
         request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_proof_http_json ~config:(Mcp_server.workspace_config state) req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/resolve" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_resolve_body state operator_name request reqd))
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/retry" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_retry_body state operator_name request reqd))
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/schedule/prune" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           let config = Mcp_server.workspace_config state in
           match dashboard_schedule_prune_http_json ~config ~operator_name with
           | Ok json -> respond_json_value_with_cors request reqd json
           | Error message ->
             respond_json_value_with_cors ~status:`Bad_request request reqd
               (operator_error_json message)
         )
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/gate/rules/delete" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _operator_name _req reqd ->
           Http.Request.read_body_async reqd
             (handle_gate_rule_delete_body state request reqd))
         request reqd)

  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
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
       ) request reqd)
  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json_value ~compress:true ~request:req json reqd
         | Error message ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
       ) request reqd)
  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_operator_action" (fun state authorized_actor req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
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
       ) request reqd)
  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_operator_confirm" (fun state authorized_actor req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
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
       ) request reqd)

  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "planning:%s"
             (Mcp_server.workspace_config state).base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_planning_http_json ~config:(Mcp_server.workspace_config state)))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/bootstrap" (fun request reqd ->
       (* Cold-start bootstrap: routes to the shared SSOT
          [dashboard_bootstrap_http_json] in [Server_dashboard_http] so
          the HTTP/1.1 router and HTTP/2 gateway return identical
          payloads.  Slice list, error contract, and per-slice
          exception capture all live in the SSOT; this handler is
          just the auth + transport wrapper. *)
       with_public_read (fun state req reqd ->
         let json = dashboard_bootstrap_http_json ~state ~sw ~clock req in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "goals_tree:%s"
             (Mcp_server.workspace_config state).base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_goals_tree_http_json ~config:(Mcp_server.workspace_config state)))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals/detail" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let goal_id =
           Server_utils.query_param req "goal_id"
           |> Option.map String.trim
           |> Option.value ~default:""
         in
         if goal_id = "" then
           respond_public_read_json_value ~status:`Bad_request req reqd
             (dashboard_error_json ~ok:false "goal_id query param is required")
         else
           let cache_key =
             Printf.sprintf "goal_detail:%s:%s"
               (Mcp_server.workspace_config state).base_path goal_id
           in
           let json =
             Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
               Domain_pool_ref.submit_io_or_inline (fun () ->
                 dashboard_goal_detail_http_json
                   ~config:(Mcp_server.workspace_config state) ~goal_id))
           in
           Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tasks/history" (fun request reqd ->
       with_public_read (fun state req reqd ->
         handle_dashboard_task_history state req reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Server_dashboard_http_core_cache.dashboard_query_cache_key
             (Mcp_server.workspace_config state)
             "briefing"
             [ ("actor", dashboard_actor_cache_segment state req) ]
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:live_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_briefing_http_json ~state ~sw ~clock req))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tools" (fun request reqd ->
       with_public_read (fun state req reqd ->
           let timing = Server_timing.create () in
           (* RFC-0138 Phase 3 Step 2: wait-free read via
              [Dashboard_snapshot.current ()] for the global catalog. An exact
              Keeper selector computes the effective surface beside it. *)
           let json =
             Server_dashboard_snapshot_select.select_tools_json
               ~timing
               ?keeper:(Server_utils.query_param request "keeper")
               (Mcp_server.workspace_config state)
           in
         Http.Response.json_value ~compress:true ~request:req ~extra_headers:(Server_timing.extra_header timing) json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/skill-activations" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let extra_headers = public_read_cors_headers req in
         match Server_utils.query_param req "trace_id" |> Option.map String.trim with
         | None | Some "" ->
           Http.Response.json_value ~compress:true ~request:req
             ~status:`Bad_request ~extra_headers
             (dashboard_error_json "trace_id query param is required") reqd
         | Some raw_trace_id ->
           (match
              Domain_pool_ref.submit_io_or_inline (fun () ->
                Keeper_skill_activation_projection.resolve_trace_string
                  ~config:(Mcp_server.workspace_config state)
                  raw_trace_id)
            with
            | Error detail ->
              Http.Response.json_value ~compress:true ~request:req
                ~status:`Bad_request ~extra_headers
                (dashboard_error_json detail) reqd
            | Ok projection ->
              let json =
                Keeper_skill_activation_projection.trace_to_yojson projection
              in
              Http.Response.json_value ~compress:true ~request:req
                ~extra_headers json reqd)
       ) request reqd)
  (* Schedule projection, served by its owner. The no-query aggregate keeps its
     shared live cache; an exact schedule_id lookup reads the same ledger and
     row encoder without adding a client-controlled cache key. *)
  |> Http.Router.get "/api/v1/dashboard/scheduled-automation" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           Server_dashboard_http.dashboard_scheduled_automation_query_http_json
             ~config:(Mcp_server.workspace_config state)
             req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/briefing/sections" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           if Server_utils.bool_query_param req "force" ~default:false then
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_briefing_sections_http_json ~state ~sw ~clock req)
           else
             let cache_key =
               Server_dashboard_http_core_cache.dashboard_query_cache_key
                 (Mcp_server.workspace_config state)
                 "mission_briefing"
                 [ ("actor", dashboard_actor_cache_segment state req) ]
             in
             Dashboard_cache.get_or_compute cache_key ~ttl:live_cache_ttl_s (fun () ->
               Domain_pool_ref.submit_io_or_inline (fun () ->
                 dashboard_briefing_sections_http_json ~state ~sw ~clock req))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tool-quality" (fun request reqd ->
       with_public_read (fun _state req reqd ->
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
         let cache_key =
           Printf.sprintf "tool_quality:%d:%s" n
             (match window_hours with
              | Some w -> Printf.sprintf "%.2f" w
              | None -> "-")
         in
         (* TTL extended 5s→30s — [aggregate ~n:5000] over a 24h window was
            measured at 30s cache miss (curl --max-time 30 timeout in the
            page→endpoint profile). The window itself is hours-scale so
            6× longer TTL still serves near-live data; under 30s window the
            poll just hit the previous compute and never wait 30s again. *)
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:config_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_http_tool_quality.aggregate ~n ?window_hours ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/transport-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         (* No route cache here. The producer is not a computation — it reads a
            published cell and derives cache_state, stale_reason and
            stale_age_ms from it. A second 30s cache in front of that served
            the previous "fresh" payload after the inner surface had gone to an
            error state, and froze stale_age_ms, so a client watching the age
            saw it stand still while the surface aged (#27652). Every other
            route cache on this router wraps an actual computation. *)
         let json = dashboard_transport_health_http_json ~state in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/perf" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_perf_http_json (Mcp_server.workspace_config state) in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/clients" (fun request reqd ->
       with_public_read (fun state req reqd ->
         (* Everyone attached to this workspace in one reading: directory
            agents, state-backed sessions, and runtime fibers, merged by
            [dashboard_agents_safe]. The TUI's Runtime family reads this to
            answer "who is connected", which no other surface lists — the
            keeper roster carries keepers only, so a non-keeper MCP client
            is invisible there. Sorted by name so two readings a refresh
            apart diff as row changes, not reorderings. Observation-only:
            joining a session to its task binding is a read, and the
            backlog stays the authority on ownership. *)
         let config = Mcp_server.workspace_config state in
         let agents =
           List.sort
             (fun (a : Masc_domain.agent) (b : Masc_domain.agent) ->
                String.compare a.name b.name)
             (dashboard_agents_safe config)
         in
         let json =
           `Assoc
             [ ("schema", `String "masc.dashboard.clients.v1")
             ; ("generated_at", `String (Masc_domain.now_iso ()))
             ; ("observation_only", `Bool true)
             ; ("clients", `List (List.map dashboard_agent_json agents))
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/harness-health" (fun _request reqd ->
       with_public_read (fun state req reqd ->
         let since = Server_utils.query_param req "since" in
         let until = Server_utils.query_param req "until" in
         let cache_key =
           Printf.sprintf "harness_health:%s:%s:%s"
             (Mcp_server.workspace_config state).base_path
             (Option.value ~default:"-" since)
             (Option.value ~default:"-" until)
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_harness_health.json ?since ?until ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) _request reqd)
  (* An operator's own verdict on a harness row. The label is ground truth
     for judge calibration, so it takes the admin permission and the
     authenticated caller becomes the labeler — no anonymous ground truth. *)
  |> Http.Router.post "/api/v1/dashboard/harness-label" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match Dashboard_harness_health.parse_label_body body_str with
             | Error message ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd message
             | Ok label ->
               Dashboard_harness_health.record_operator_label
                 ~labeler:agent_name label;
               Http.Response.json_value ~request:req
                 (`Assoc [ "ok", `Bool true ]) reqd))
         request reqd)
  |> Http.Router.get "/api/v1/dashboard/feature-health" (fun _request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "feature_health" in
         (* TTL extended 10s→60s — feature flags + provider rollups move on
            minute scale, but the compute was measured at 3.5s (page→endpoint
            profile, cold or near-expiry). 10s TTL means every 11th poll
            eats 3.5s; 60s collapses to 1/60 polls. *)
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:feature_health_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_feature_health.json ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) _request reqd)
  (* ── Eval feed (RFC-MASC-005 Phase 2) ── *)
  |> Http.Router.get "/api/v1/dashboard/eval-feed" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let agent_name = Server_utils.query_param req "agent_name" in
         let limit =
           Server_utils.int_query_param req "limit" ~default:10
           |> max 1 |> min 100
         in
         let cache_key =
           Printf.sprintf "eval_feed:%s:%s:%d"
             base_path
             (Option.value ~default:"-" (Option.map String.trim agent_name))
             limit
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
         match agent_name with
           | Some name when String.trim name <> "" ->
               let snapshots =
                 Dashboard_eval_feed.read_latest ~base_path
                   ~agent_name:(String.trim name) ~limit
               in
               `Assoc [
                 ("generated_at", `String (Masc_domain.now_iso ()));
                 ("agent_name", `String (String.trim name));
                 ("count", `Int (List.length snapshots));
                 ("snapshots", `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots));
               ]
           | _ ->
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
               ]))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* ── Telemetry unified view ── *)
  |> Http.Router.get "/api/v1/dashboard/telemetry" handle_telemetry
  |> Http.Router.get "/api/v1/dashboard/telemetry/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
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
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/agent_core/telemetry/recent" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = agent_core_telemetry_provider_param req in
         let limit = agent_core_telemetry_limit_param req in
         let json = Dashboard_agent_core_bridge.recent_json ?provider ~limit () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/agent_core/telemetry/summary" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = agent_core_telemetry_provider_param req in
         let limit = agent_core_telemetry_limit_param req in
         let json = Dashboard_agent_core_bridge.summary_json ?provider ~limit () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* ── Dashboard delete actions (extracted) ── *)
  |> Server_dashboard_http_delete_actions.add_delete_action_routes

  (* Bulk keeper directive — operator can pause/resume/wakeup N keepers in
     one round-trip with a single batch cache invalidate at the end. The
     URL prefix is intentionally outside [/api/v1/keepers/] so it does not
     collide with the per-name [prefix_post] catch-all below. *)
  |> Http.Router.post "/api/v1/keepers_bulk/directive" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             Keeper_api.handle_keeper_bulk_directive_post
               ~sw ~clock state agent_name req reqd body_str))
         request reqd)

  |> Http.Router.post "/api/v1/keepers/chat/stream" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_keeper_delegate" (fun state submitted_by _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_keeper_chat_stream_request body_str with
           | Ok payload ->
               handle_keeper_chat_stream
                 ~sw
                 ~clock
                 ~submitted_by
                 state
                 request
                 reqd
                 payload
           | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (keeper_chat_stream_error_json message)
         )
       ) request reqd)

  (* Keeper GET sub-routes: /config, /chat/history, /trajectory *)
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       match Keeper_chat_operations.get_route (Http.Request.path request) with
       | Some route ->
         with_token_permission_auth
           ~permission:(Keeper_chat_operations.get_permission route)
           (fun state _agent_name req reqd ->
             Keeper_chat_operations.handle_get state req reqd route)
           request
           reqd
       | None ->
         (match
            Keeper_api.keeper_get_permission
              ~include_thinking:
                (Server_utils.bool_query_param request "include_thinking"
                   ~default:false)
              (Http.Request.path request)
          with
          | Some permission ->
           with_token_permission_auth ~permission
             (fun state _agent_name req reqd ->
               Keeper_api.handle_keeper_get_subroutes state req request reqd
             ) request reqd
          | None ->
           with_public_read (fun state req reqd ->
             Keeper_api.handle_keeper_get_subroutes state req request reqd
           ) request reqd))

  |> Http.Router.post "/api/v1/keepers/turn/interrupt" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_delegate_cancel" (fun state _req reqd ->
         handle_keeper_turn_interrupt state request reqd) request reqd)

  (* Answers a tool call the keeper is holding. Same authority as interrupting
     a turn: both decide what a running turn is allowed to do next. The route
     carries its own catalog auth key (keeper_tool_approval_route) rather than
     borrowing a dispatchable tool's name, so the permission it enforces stays
     reviewable on its own terms. *)
  |> Http.Router.post "/api/v1/keepers/tool-approval" (fun request reqd ->
       with_tool_auth ~tool_name:"keeper_tool_approval_route" (fun state _req reqd ->
         handle_keeper_tool_approval state request reqd) request reqd)

  (* What one Keeper is waiting on a human for. *)
  |> Http.Router.get "/api/v1/keepers/asks" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_ask_status" (fun state _req reqd ->
         handle_keeper_asks_list state request reqd) request reqd)

  (* Answers a Keeper's question. The operator may be at any surface; the
     log settles concurrent submissions on first write. *)
  |> Http.Router.post "/api/v1/keepers/ask-answer" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_ask" (fun state _req reqd ->
         handle_keeper_ask_answer state request reqd) request reqd)

  (* Lists the tool calls keepers are holding, so a wait whose owning stream
     watcher is gone can still be answered instead of only timing out
     (masc#30034). Read authority follows the operator snapshot (public
     read): the listing names what is being asked; answering stays behind
     the authed POST above. *)
  |> Http.Router.get "/api/v1/keepers/tool-approvals" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_keeper_tool_approvals_list state request reqd) request reqd)

  (* Which keepers are mid-turn right now. Read-only Owner projection with
     the same read authority as the listing above: it names activity, and
     every mutation stays behind its own authed route. *)
  |> Http.Router.get "/api/v1/keepers/turns" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_keeper_turns_list state request reqd) request reqd)

  (* The per-keeper approval stance the gate consults per call. Reading the
     overrides is a public-read projection like the listing above; setting
     one decides what a running turn may do next, so it carries the same
     authority as answering a held call (and its own catalog auth key,
     keeper_tool_approval_mode_route). *)
  |> Http.Router.get "/api/v1/keepers/tool-approval-mode" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_keeper_tool_approval_mode_get state request reqd) request reqd)
  |> Http.Router.post "/api/v1/keepers/tool-approval-mode" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"keeper_tool_approval_mode_route"
         (fun state agent_name _req reqd ->
           handle_keeper_tool_approval_mode_set ~actor:agent_name state request
             reqd)
         request reqd)

  (* Keeper POST sub-routes. *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       match Keeper_chat_operations.mutation_route (Http.Request.path request) with
       | Some route ->
         with_token_permission_auth
           ~permission:Keeper_chat_operations.mutation_permission
           (fun state _agent_name req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               Keeper_chat_operations.handle_mutation
                 state
                 req
                 reqd
                 route
                 body_str))
           request
           reqd
       | None ->
       match Keeper_event_queue_operator.route (Http.Request.path request) with
       | Some keeper_name ->
         with_token_permission_auth
           ~permission:Keeper_event_queue_operator.operator_permission
           (fun state agent_name req reqd ->
             Http.Request.read_body_async reqd (fun body_str ->
               Keeper_event_queue_operator.handle_post
                 state
                 ~actor:agent_name
                 req
                 reqd
                 ~keeper_name
                 body_str))
           request reqd
       | None ->
       match Keeper_api.classify_keeper_post_route (Http.Request.path request) with
       | Keeper_api.Keeper_post_board_attention_quarantine_recovery
           { keeper_name; partition_id } ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_board_attention_quarantine_recovery_post
                   state
                   agent_name
                   req
                   reqd
                   ~keeper_name
                   ~raw_partition_id:partition_id
                   body_str))
             request reqd
       | Keeper_api.Keeper_post_config ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_secrets ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_secrets_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_github_login ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Keeper_api.handle_keeper_github_login_post state req reqd)
             request reqd
       | Keeper_api.Keeper_post_identity_refresh ->
           (* Reads from a provider and writes a catalog into this keeper's
              own state, so it carries the same authority as starting the
              login that produced the credential. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_identity_refresh_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_identity_switch ->
           (* Decides whether this keeper's turns are handed that provider's
              tools at all, so it carries the same authority as the attach
              that produced them. The operator name feeds the audit row. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_identity_switch_post state
                   ~actor:agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_oauth_login ->
           (* Same authority as writing a secret by hand: what this begins
              ends with credentials in that keeper's scope. *)
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_oauth_login_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_boot ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_up"
                 ~action:"boot" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_up ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                   Keeper_api.handle_keeper_lifecycle_post ~body_str ~sw ~clock
                     ~tool_name:"masc_keeper_up" ~action:"up"
                     state agent_name req reqd
               )
             ) request reqd
       | Keeper_api.Keeper_post_shutdown ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_down"
                 ~action:"shutdown" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_reset ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_reset"
                 ~action:"reset" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_clear ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_lifecycle_post ~body_str ~sw ~clock
                   ~tool_name:"masc_keeper_clear" ~action:"clear"
                   state agent_name req reqd
               )
             ) request reqd
       | Keeper_api.Keeper_post_checkpoints ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_checkpoints_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_directive ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_directive_post
                   ~sw ~clock state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_paused_work ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_paused_work_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_fusion ->
           with_tool_auth ~tool_name:"masc_fusion"
             (fun state req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_fusion_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_operator_note ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_operator_note_post
                   state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_unknown ->
           respond_dashboard_error ~status:`Not_found reqd "not found")

  (* ── Agent API routes (extracted) ── *)
  |> Server_dashboard_http_agent_api.add_agent_api_routes
