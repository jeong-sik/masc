(* server_routes_http_routes_dashboard — dashboard route registration.

   Setup (module aliases, helpers, handlers) and telemetry endpoint
   extracted to Server_routes_http_routes_dashboard_setup as part of
   godfile near-threshold split. *)

open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

module Runtime_config_file = Runtime

include Server_routes_http_routes_dashboard_setup

let config_cache_ttl_s = Server_dashboard_http_core_cache.config_cache_ttl_s
let standard_cache_ttl_s = Server_dashboard_http_core_cache.standard_cache_ttl_s
let live_cache_ttl_s = Server_dashboard_http_core_cache.live_cache_ttl_s
let realtime_cache_ttl_s = Server_dashboard_http_core_cache.realtime_cache_ttl_s
let feature_health_cache_ttl_s = Server_dashboard_http_core_cache.feature_health_cache_ttl_s

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

let respond_dashboard_error ?(status = `Bad_request) ?request ?ok reqd message =
  Http.Response.json_value ?request ~status
    (dashboard_error_json ?ok message)
    reqd

let respond_dashboard_ok ?request reqd =
  Http.Response.json_value ?request ~compress:true
    (`Assoc [ ("ok", `Bool true) ])
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

let runtime_config_raw_json ~path ~source_text ~reloaded =
  `Assoc
    [ ("ok", `Bool true)
    ; ("path", `String path)
    ; ("file_name", `String "runtime.toml")
    ; ("source_text", `String source_text)
    ; ("reloaded", `Bool reloaded)
    ]

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

type runtime_route_lane =
  | Runtime_default
  | Runtime_librarian
  | Runtime_structured_judge
  | Runtime_hitl_summary
  | Runtime_cross_verifier
  | Runtime_media_failover

let runtime_route_lane_to_string = function
  | Runtime_default -> "default"
  | Runtime_librarian -> "librarian"
  | Runtime_structured_judge -> "structured_judge"
  | Runtime_hitl_summary -> "hitl_summary"
  | Runtime_cross_verifier -> "cross_verifier"
  | Runtime_media_failover -> "media_failover"

let parse_runtime_route_lane = function
  | "default" -> Ok Runtime_default
  | "librarian" -> Ok Runtime_librarian
  | "structured_judge" -> Ok Runtime_structured_judge
  | "hitl_summary" -> Ok Runtime_hitl_summary
  | "cross_verifier" -> Ok Runtime_cross_verifier
  | "media_failover" -> Ok Runtime_media_failover
  | lane -> Error (Printf.sprintf "unknown runtime routing lane: %s" lane)

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
         (match optional_string_field json "runtime_id" with
          | Error _ as err -> err
          | Ok runtime_id -> Ok (keeper_name, runtime_id)))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

let runtime_config_path_error_status message =
  if String.equal message "runtime config path not found"
  then `Not_found
  else `Internal_server_error

type runtime_config_write_operation =
  | Runtime_config_reload
  | Runtime_config_raw_save
  | Runtime_config_routing of runtime_route_lane * string option
  | Runtime_config_routing_list of runtime_route_lane * string list
  | Runtime_config_assignment of string * string option

let runtime_config_write_operation_details = function
  | Runtime_config_reload -> [ ("operation", `String "reload") ]
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

let audit_runtime_config_write state agent_name ?path ~operation ~text ~outcome () =
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
              ]))
      ~outcome
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Dashboard.warn
      "runtime.toml audit log failed: %s"
      (Printexc.to_string exn)

let respond_runtime_config_reload state agent_name ~operation request reqd =
  match Runtime_config_file.load_config_text () with
  | Ok (path, saved_text) ->
    audit_runtime_config_write state agent_name ~path ~operation ~text:saved_text
      ~outcome:Audit_log.Success ();
    Http.Response.json_value ~compress:true ~request
      (runtime_config_raw_json ~path ~source_text:saved_text ~reloaded:true)
      reqd
  | Error msg ->
    respond_dashboard_error
      ~status:(runtime_config_path_error_status msg)
      ~request reqd msg

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
  |> Http.Router.get "/api/v1/dashboard/nudges" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:50
           |> Server_utils.clamp ~min_v:1 ~max_v:200
         in
         let cache_key =
           Printf.sprintf "nudges:%s:%d"
             (Mcp_server.workspace_config state).base_path limit
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:realtime_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_operator_nudges.json
                 ~config:(Mcp_server.workspace_config state) ~limit ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goal-loop/status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           Dashboard_goal_loop.status_json
             ~base_path:(Mcp_server.workspace_config state).base_path ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  (* RFC-0266 §7 Phase 4: read-only snapshot of the in-memory fusion run registry
     (in-progress + recently completed). The fusion panel fetches this on load and
     re-fetches on the [fusion_run_status] SSE event. Registry reads are O(runs)
     in-memory, so no Dashboard_cache layer; each run serializes through the shared
     Fusion_run_registry.run_to_yojson so the shape matches the SSE delta. *)
  |> Http.Router.get "/api/v1/dashboard/fusion-runs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let runs = Fusion_run_registry.list_runs (Fusion_run_registry.global ()) in
         let json =
           `Assoc
             [ ("generated_at", `String (Masc_domain.now_iso ()))
             ; ("count", `Int (List.length runs))
             ; ("runs", `List (List.map Fusion_run_registry.run_to_yojson runs))
             ]
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/branches" (fun request reqd ->
       with_public_read (fun state req reqd ->
         (* /branches spawns `git -C <repo> branch` via Exec_gate. Cache +
            offload (respond_cached_read) so a parallel dashboard burst
            collapses to one git spawn per realtime TTL and the spawn runs on
            an Executor_pool domain instead of blocking the main HTTP domain. *)
         let cache_key =
           Printf.sprintf "branches:%s"
             (Mcp_server.workspace_config state).base_path
         in
         respond_cached_read ~request:req ~reqd ~cache_key
           ~ttl:realtime_cache_ttl_s (fun () ->
             Dashboard_branches.json ~config:(Mcp_server.workspace_config state))
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/workspace" (fun request reqd ->
       with_public_read handle_dashboard_workspace request reqd)
  (* Dev-only shared bearer for the dashboard UI. Served exclusively when the
     server binds to loopback and strict-auth env overrides are disabled, so
     that a LAN deployment never hands out a token over the wire. The token is
     canonicalized to the [dashboard] actor and persisted at
     [.masc/auth/dashboard.token]. *)
  |> Http.Router.get "/api/v1/dashboard/dev-token" (fun request reqd ->
       if (not (http_auth_bind_is_loopback ()))
          || http_auth_strict_enabled () then
         respond_dashboard_error ~status:`Not_found ~request reqd
           "dev-token endpoint disabled (non-loopback bind or strict auth)"
       else
         with_public_read (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let raw_result =
             Server_routes_http_dashboard_dev_token.ensure_dashboard_dev_token_for_request
               ~request:req
               ~base_path
           in
           begin
             match raw_result with
             | Ok raw ->
               Http.Response.json_value ~request:req
                 (`Assoc [ ("token", `String raw) ]) reqd
             | Error err ->
               let status =
                 match err with
                 | Server_routes_http_dashboard_dev_token.Request_host_rejected _ ->
                   `Forbidden
                 | Server_routes_http_dashboard_dev_token.Token_operation_failed _ ->
                   `Internal_server_error
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
       with_tool_auth ~tool_name:"masc_runtime_ollama_probe" handle request reqd)
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
  |> Http.Router.get "/api/v1/runtime/config/raw" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
           match Runtime_config_file.load_config_text () with
           | Ok (path, source_text) ->
             Http.Response.json_value ~compress:true ~request:req
               (runtime_config_raw_json ~path ~source_text ~reloaded:false)
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
  |> Http.Router.post "/api/v1/runtime/config/raw" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             match parse_runtime_config_raw_body body_str with
             | Error msg ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
             | Ok source_text ->
               (* RFC-0273 §3.3 — record the runtime.toml write to the governance
                  audit trail (actor + path + size) on top of the CanAdmin gate.
                  The config body is deliberately excluded: runtime.toml can carry
                  provider secrets (RFC-0132 redaction). *)
               (match Runtime_config_file.save_config_text source_text with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:Runtime_config_raw_save ~text:source_text
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:Runtime_config_raw_save req reqd)
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
               (match Runtime_config_file.set_runtime_default ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:(Runtime_config_routing (Runtime_default, Some runtime_id))
                    req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_default, None)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 "default runtime_id required"
             | Ok (Runtime_route_runtime_id (Runtime_librarian, runtime_id)) ->
               (match Runtime_config_file.set_runtime_librarian ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:(Runtime_config_routing (Runtime_librarian, runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:(Runtime_config_routing (Runtime_librarian, runtime_id))
                    req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_structured_judge, runtime_id)) ->
               (match Runtime_config_file.set_runtime_structured_judge ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_structured_judge, runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_structured_judge, runtime_id))
                    req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_hitl_summary, runtime_id)) ->
               (match Runtime_config_file.set_runtime_hitl_summary ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_hitl_summary, runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_hitl_summary, runtime_id))
                    req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_cross_verifier, runtime_id)) ->
               (match Runtime_config_file.set_runtime_cross_verifier ~runtime_id () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_cross_verifier, runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:
                      (Runtime_config_routing (Runtime_cross_verifier, runtime_id))
                    req reqd)
             | Ok (Runtime_route_runtime_id (Runtime_media_failover, _)) ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd
                 "media_failover runtime_ids required"
             | Ok (Runtime_route_runtime_ids (Runtime_media_failover, runtime_ids)) ->
               (match Runtime_config_file.set_runtime_media_failover ~runtime_ids () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:
                      (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:
                      (Runtime_config_routing_list (Runtime_media_failover, runtime_ids))
                    req reqd)
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
             match parse_runtime_assignment_body body_str with
             | Error msg ->
               respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
             | Ok (keeper_name, Some runtime_id) ->
               (match
                  Runtime_config_file.set_runtime_id_for_keeper
                    ~keeper_name
                    ~runtime_id
                    ()
                with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:(Runtime_config_assignment (keeper_name, Some runtime_id))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:(Runtime_config_assignment (keeper_name, Some runtime_id))
                    req reqd)
             | Ok (keeper_name, None) ->
               (match Runtime_config_file.clear_runtime_id_for_keeper ~keeper_name () with
                | Error msg ->
                  audit_runtime_config_write state agent_name
                    ~operation:(Runtime_config_assignment (keeper_name, None))
                    ~text:body_str
                    ~outcome:(Audit_log.Failure msg) ();
                  respond_dashboard_error ~status:`Bad_request ~request:req reqd msg
                | Ok () ->
                  respond_runtime_config_reload state agent_name
                    ~operation:(Runtime_config_assignment (keeper_name, None))
                    req reqd)
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
           let json =
             dashboard_logs_json ~config:(Mcp_server.workspace_config state) ~limit
               ~level_filter ~applied_level ~min_level ~module_filter ~since_seq
               ~before_seq ~category_filter ~exclude_category entries
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
  |> Http.Router.get "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "excuse_patterns" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:config_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               let patterns = Task.Anti_rationalization.load_excuse_patterns () in
               let json_items =
                 List.map
                   (fun (pat, reason) -> `List [ `String pat; `String reason ])
                   patterns
               in
               `List json_items))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             try
               let json = Yojson.Safe.from_string body_str in
               match Task.Anti_rationalization.parse_excuse_patterns_json json with
               | Error msg ->
                 Http.Response.json_value ~status:`Bad_request ~request:req
                   (`Assoc [("ok", `Bool false); ("error", `String msg)]) reqd
               | Ok patterns ->
                 (match Task.Anti_rationalization.save_excuse_patterns patterns with
                 | Ok () ->
                     respond_dashboard_ok ~request:req reqd
                 | Error msg ->
                     Http.Response.json_value ~status:`Internal_server_error ~request:req
                       (`Assoc [("ok", `Bool false); ("error", `String msg)]) reqd)
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | _exn ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [("ok", `Bool false); ("error", `String "Invalid JSON body")]) reqd
           )
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
  |> Http.Router.get "/api/v1/dashboard/namespace-truth" (fun request reqd ->
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
  |> Http.Router.get "/api/v1/dashboard/memory-subsystems" (fun request reqd ->
       let include_memory_entries =
         dashboard_memory_subsystems_include_entries request
       in
       let handler state req reqd =
         let config = (Mcp_server.workspace_config state) in
         let cache_key =
           Printf.sprintf "memory_subsystems:%s:%b"
             config.base_path include_memory_entries
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_memory_subsystems_http_json ~config
                 ~include_memory_entries req))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       in
       if include_memory_entries then
         with_token_permission_auth ~permission:Masc_domain.CanReadState
           (fun state _agent_name req reqd -> handler state req reqd)
           request reqd
       else with_public_read handler request reqd)
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
  |> Http.Router.get "/api/v1/dashboard/legacy-keeper-inventory" (fun request reqd ->
       with_permission_auth ~permission:Masc_domain.CanAdmin (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let max_depth =
           Server_utils.int_query_param
             req
             "max_depth"
             ~default:
               Server_dashboard_http_legacy_keeper_inventory.default_max_depth
           |> Server_utils.clamp ~min_v:0 ~max_v:8
         in
         let max_entries =
           Server_utils.int_query_param
             req
             "max_entries"
             ~default:
               Server_dashboard_http_legacy_keeper_inventory.default_max_entries
           |> Server_utils.clamp ~min_v:1 ~max_v:50_000
         in
         let cache_key =
           let base_hash =
             Digestif.SHA256.(digest_string base_path |> to_hex)
             |> fun hex -> String.sub hex 0 16
           in
           Printf.sprintf
             "legacy_keeper_inventory:%s:%d:%d"
             base_hash
             max_depth
             max_entries
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Executor_pool_ref.submit_or_inline (fun () ->
               Server_dashboard_http_legacy_keeper_inventory.legacy_keeper_inventory_http_json
                 ~base_path
                 ~max_depth
                 ~max_entries
                 ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/interaction-judge" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = Dashboard_interaction_judge.fresh_interactions_json ~base_path in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance/tool-events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_governance_tool_events_http_json req in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance/approval-mode" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _operator_name _req reqd ->
           let config = Mcp_server.workspace_config state in
           let json =
             Operator_approval.approval_mode_status_json
               ~base_path:config.base_path
           in
           respond_json_value_with_cors request reqd json)
         request reqd)
  |> Http.Router.post "/api/v1/dashboard/governance/approval-mode" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             try
               let args = Yojson.Safe.from_string body_str in
               let mode_json =
                 match args with
                 | `Assoc fields -> List.assoc_opt "mode" fields
                 | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
                 | `String _ ->
                   None
               in
               match mode_json with
               | None ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd
                   (operator_error_json "mode is required")
               | Some mode_json ->
                 (match Operator_approval.parse_approval_mode_json mode_json with
                  | Error msg ->
                    respond_json_value_with_cors ~status:`Bad_request request reqd
                      (operator_error_json msg)
                  | Ok mode ->
                    let config = Mcp_server.workspace_config state in
                    (match
                       Operator_approval.set_approval_mode
                         config
                         ~actor:operator_name
                         mode
                     with
                     | Error msg ->
                       respond_json_value_with_cors ~status:`Bad_request request reqd
                         (operator_error_json msg)
                     | Ok change ->
                       Dashboard_cache.invalidate_prefix
                         (Printf.sprintf "governance:%s;" config.base_path);
                       Sse.broadcast
                         (`Assoc
                            [ "type", `String "approval_mode_changed"
                            ; "mode",
                              `String (Operator_approval.approval_mode_to_string mode)
                            ; "previous_mode",
                              `String
                                (Operator_approval.approval_mode_to_string
                                   change.previous)
                            ; "actor", `String operator_name
                            ; "changed_at", `String change.changed_at
                            ]);
                       respond_json_value_with_cors request reqd
                         (Operator_approval.approval_mode_change_json change)))
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | Yojson.Json_error msg ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
         )
         request reqd)
  |> Http.Router.get "/api/v1/dashboard/repository-observation-snapshot" (fun request reqd ->
       Server_dashboard_http.handle_repository_observation_snapshot ~sw ~clock request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_proof_http_json ~config:(Mcp_server.workspace_config state) req
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/governance/approvals/resolve" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = (Mcp_server.workspace_config state).base_path in
             match dashboard_governance_approval_resolve_http_json ~base_path ~args with
             | Ok json ->
                 respond_json_value_with_cors request reqd json
             | Error (Gone _ as err) ->
                 respond_json_value_with_cors ~status:`Not_found request reqd (operator_error_json (approval_resolve_http_error_to_string err))
             | Error (Unavailable _ as err) ->
                 respond_json_value_with_cors ~status:`Service_unavailable request reqd (operator_error_json (approval_resolve_http_error_to_string err))
             | Error (Bad_request _ as err) ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (approval_resolve_http_error_to_string err))
           with Yojson.Json_error msg ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (Printf.sprintf "invalid json: %s" msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/schedule/resolve" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state operator_name _req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             try
                 let args = Yojson.Safe.from_string body_str in
                 let config = Mcp_server.workspace_config state in
                 match
                   dashboard_schedule_resolve_http_json ~config ~operator_name ~args
                 with
               | Ok json -> respond_json_value_with_cors request reqd json
               | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd
                   (operator_error_json message)
             with
             | Yojson.Json_error msg ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
         )
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
  |> Http.Router.post "/api/v1/dashboard/governance/approvals/rules/delete" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = (Mcp_server.workspace_config state).base_path in
             match
               dashboard_governance_approval_rule_delete_http_json ~base_path ~args
             with
             | Ok json ->
                 respond_json_value_with_cors request reqd json
             | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
           with Yojson.Json_error msg ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (Printf.sprintf "invalid json: %s" msg))
         )
       ) request reqd)

  (* Operator surface restored after cp-purge (#7349): handlers existed in
     server_dashboard_http_core/.ml but their Router.get/post registrations
     were deleted together with the Command Plane. Dashboard SSE hydrates
     the same caches, so this path only services HTTP fallbacks (first load
     before SSE attaches + explicit tab-refresh). *)
  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "operator_snapshot:%s"
             (Mcp_server.workspace_config state).base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:realtime_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               operator_snapshot_http_json ~state ~sw ~clock req))
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
       with_tool_auth ~tool_name:"masc_operator_action" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_value_with_cors request reqd json
             | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json message)
           with Yojson.Json_error msg ->
             respond_json_value_with_cors ~status:`Bad_request request reqd (operator_error_json (Printf.sprintf "invalid json: %s" msg))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
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
  |> Http.Router.get "/api/v1/dashboard/session" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Server_dashboard_http_core_cache.dashboard_query_cache_key
             (Mcp_server.workspace_config state)
             "session"
             [ ("actor", dashboard_actor_cache_segment state req)
             ; ("session", Server_utils.query_param req "session_id")
             ]
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:live_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_session_http_json ~state ~sw ~clock req))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tools" (fun request reqd ->
       with_public_read (fun state req reqd ->
           let timing = Server_timing.create () in
           (* RFC-0138 Phase 3 Step 2: wait-free read via
              [Dashboard_snapshot.current ()] when an actor filter is
              not requested.  Per-actor variant continues through
              [dashboard_tools_http_json] until the snapshot type
              grows an [Actor_filter] arm. *)
           let json =
             Server_dashboard_snapshot_select.select_tools_json
               ~timing
               ?actor:
                 (dashboard_actor_for_request
                    ~base_path:(Mcp_server.workspace_config state).base_path request)
               (Mcp_server.workspace_config state)
           in
         Http.Response.json_value ~compress:true ~request:req ~extra_headers:(Server_timing.extra_header timing) json reqd
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
  |> Http.Router.get "/api/v1/dashboard/surface-readiness" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let surface_id = Server_utils.query_param req "surface_id" in
         let cache_key =
           Printf.sprintf "surface_readiness:%s"
             (Option.value ~default:"-" surface_id)
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_surface_readiness.json ?surface_id ()))
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
  |> Http.Router.get "/api/v1/dashboard/keeper-feature-proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let window_hours =
           match Server_utils.query_param req "window_hours" with
           | Some s ->
             (match float_of_string_opt s with
              | Some value when Float.is_finite value ->
                Some (max 0.1 (min 168.0 value))
              | Some _ | None -> None)
           | None -> None
         in
         let config = (Mcp_server.workspace_config state) in
         let cache_key =
           Printf.sprintf "keeper_feature_proof:%s:%s"
             config.base_path
             (match window_hours with
              | Some w -> Printf.sprintf "%.2f" w
              | None -> "-")
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:standard_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_keeper_feature_proof.json
                 ~config ?window_hours ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/transport-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key = "transport_health" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:live_cache_ttl_s (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_transport_health_http_json ~state))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/perf" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_perf_http_json (Mcp_server.workspace_config state) in
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
               Dashboard_harness_health.json ~config:(Mcp_server.workspace_config state)
                 ?since ?until ()))
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) _request reqd)
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
  |> Http.Router.get "/api/v1/dashboard/oas/telemetry/recent" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = oas_telemetry_provider_param req in
         let limit = oas_telemetry_limit_param req in
         let json = Dashboard_oas_bridge.recent_json ?provider ~limit () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/oas/telemetry/summary" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = oas_telemetry_provider_param req in
         let limit = oas_telemetry_limit_param req in
         let json = Dashboard_oas_bridge.summary_json ?provider ~limit () in
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
       with_tool_auth ~tool_name:"masc_keeper_msg" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_keeper_chat_stream_request body_str with
           | Ok payload ->
               handle_keeper_chat_stream ~sw ~clock state request reqd payload
           | Error message ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (keeper_chat_stream_error_json message)
         )
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/keepers/chat/requests/" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg_result"
         (fun state _req reqd ->
           handle_keeper_chat_request_result state request reqd)
         request reqd)

  |> Http.Router.prefix_post "/api/v1/keepers/chat/requests/" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg_cancel"
         (fun state _req reqd ->
           handle_keeper_chat_request_cancel state request reqd)
         request reqd)

  (* Keeper GET sub-routes: /config, /chat/history, /trajectory *)
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       if Keeper_api.is_keeper_checkpoints_get_path (Http.Request.path request) then
         with_token_permission_auth ~permission:Masc_domain.CanAdmin
           (fun state _agent_name req reqd ->
             Keeper_api.handle_keeper_get_subroutes state req request reqd
           ) request reqd
       else
         with_public_read (fun state req reqd ->
           Keeper_api.handle_keeper_get_subroutes state req request reqd
         ) request reqd)

  |> Http.Router.post "/api/v1/keepers/turn/interrupt" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg" (fun state _req reqd ->
         handle_keeper_turn_interrupt state request reqd) request reqd)

  (* Keeper config or tools update.  This prefix_post catches ALL POST
     /api/v1/keepers/* requests.  We check the suffix BEFORE auth so that
     /tools gets with_tool_auth (localhost-friendly) while /config keeps
     with_token_permission_auth (admin token required). *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       match Keeper_api.classify_keeper_post_route (Http.Request.path request) with
       | Keeper_api.Keeper_post_tools ->
           with_tool_auth ~tool_name:"masc_keeper_up"
             (fun state req reqd ->
               Keeper_api.handle_keeper_tools_post state req reqd
             ) request reqd
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
       | Keeper_api.Keeper_post_boot ->
           with_token_permission_auth ~permission:Masc_domain.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_up"
                 ~action:"boot" state agent_name req reqd
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
       | Keeper_api.Keeper_post_catchup_judge ->
           with_tool_auth ~tool_name:"masc_fusion"
             (fun state req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_catchup_judge_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_unknown ->
           respond_dashboard_error ~status:`Not_found reqd "not found")

  (* ── Agent API routes (extracted) ── *)
  |> Server_dashboard_http_agent_api.add_agent_api_routes
