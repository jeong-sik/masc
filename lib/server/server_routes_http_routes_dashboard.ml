(* server_routes_http_routes_dashboard — dashboard route registration.

   Setup (module aliases, helpers, handlers) and telemetry endpoint
   extracted to Server_routes_http_routes_dashboard_setup as part of
   godfile near-threshold split. *)

open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

include Server_routes_http_routes_dashboard_setup

let rec add_routes ~sw ~clock router =
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
         Http.Response.json ~status:`Gone ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
             ~timing ~light state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req
           ~extra_headers:(Server_timing.extra_header timing)
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/nudges" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:50
           |> Server_utils.clamp ~min_v:1 ~max_v:200
         in
         let cache_key =
           Printf.sprintf "nudges:%s:%d"
             state.Mcp_server.room_config.base_path limit
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:2.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Dashboard_operator_nudges.json
                 ~config:state.Mcp_server.room_config ~limit ()))
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goal-loop/status" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           Dashboard_goal_loop.status_json
             ~base_path:state.Mcp_server.room_config.base_path ()
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/branches" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = Dashboard_branches.json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/rooms" (fun request reqd ->
       with_public_read handle_dashboard_rooms request reqd)
  |> Http.Router.get "/api/v1/rooms" (fun request reqd ->
       with_public_read handle_dashboard_rooms request reqd)
  (* Dev-only shared bearer for the dashboard UI. Served exclusively when the
     server binds to loopback and strict-auth env overrides are disabled, so
     that a LAN deployment never hands out a token over the wire. The token is
     canonicalized to the [dashboard] actor and persisted at
     [.masc/auth/dashboard.token]. *)
  |> Http.Router.get "/api/v1/dashboard/dev-token" (fun request reqd ->
       if (not (http_auth_bind_is_loopback ()))
          || http_auth_strict_enabled () then
         Http.Response.json ~status:`Not_found ~request:request
           {|{"error":"dev-token endpoint disabled (non-loopback bind or strict auth)"}|}
           reqd
       else
         with_public_read (fun state req reqd ->
           let base_path = state.Mcp_server.room_config.base_path in
           let raw_result = ensure_dashboard_dev_token base_path in
           begin
             match raw_result with
             | Ok raw ->
               let body =
                 Yojson.Safe.to_string (`Assoc [ ("token", `String raw) ])
               in
               Http.Response.json ~request:req body reqd
             | Error msg ->
               let body =
                 Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ])
               in
               Http.Response.json ~status:`Internal_server_error
                 ~request:req body reqd
           end) request reqd)
  |> Http.Router.get "/api/v1/dashboard/runtime-probe" (fun request reqd ->
       let force = Server_utils.bool_query_param request "force" ~default:false in
       let handle _state req reqd =
         let json = dashboard_runtime_probe_http_json ~force () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       in
       with_tool_auth ~tool_name:"masc_runtime_ollama_probe" handle request reqd)
  (* Phase 1 Action 2 — live Dashboard_cache state surface.  Renders
     hit_ratio, in-flight compute count, per-entry ttl_remaining, and
     timeout-circuit-open counts so operators can correlate slow endpoints
     (Server-Timing header) with cache contention without scraping
     /metrics.  Read-only; no env tuning side-effect. *)
  |> Http.Router.get "/api/v1/dashboard/cache-stats" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cache.stats () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
           Http.Response.json ~status:`Bad_request ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
         | Some applied_level ->
           let min_level = Log.level_to_int applied_level in
           let since_seq =
             match Server_utils.query_param req "since_seq" with
             | None -> None
             | Some _ ->
                 let seq = Server_utils.int_query_param req "since_seq" ~default:(-1) in
                 if seq < 0 then None else Some seq
           in
           let module_filter = match Server_utils.query_param req "module" with
             | Some v -> v
             | None -> ""
           in
           let entries =
             Log.Ring.recent ~limit ~min_level ~module_filter ?since_seq ()
           in
           let json =
             dashboard_logs_json ~config:state.Mcp_server.room_config ~limit
               ~level_filter ~applied_level ~min_level ~module_filter ~since_seq entries
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/provider-logs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "provider_logs" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:3.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Provider_logs.dashboard_provider_logs_json ()))
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/provider-logs/tail" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let status, json = Provider_logs.dashboard_provider_log_tail_json req in
         Http.Response.json ~status ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/logs/tool-host-failures" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_broadcast" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let fallback_agent =
             dashboard_actor_for_request
               ~base_path:state.Mcp_server.room_config.base_path request
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
                 state.Mcp_server.room_config
                 report;
               Http.Response.json ~compress:true ~request:req {|{"ok":true}|}
                 reqd
           | Error message ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [ ("ok", `Bool false); ("error", `String message) ]))
                 reqd)
       ) request reqd)
  (* RFC-0049 — surface/section open counters. Aggregate Prometheus
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
               Http.Response.json ~request:req {|{"ok":true}|} reqd
           | Error message ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc
                      [ ("ok", `Bool false); ("error", `String message) ]))
                 reqd)
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "config_introspect" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:30.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               Env_config_introspect.to_json ()))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let cache_key = "excuse_patterns" in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:30.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               let patterns = Anti_rationalization.load_excuse_patterns () in
               let json_items =
                 List.map
                   (fun (pat, reason) -> `List [ `String pat; `String reason ])
                   patterns
               in
               `List json_items))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             try
               let json = Yojson.Safe.from_string body_str in
               match Anti_rationalization.parse_excuse_patterns_json json with
               | Error msg ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])) reqd
               | Ok patterns ->
                 (match Anti_rationalization.save_excuse_patterns patterns with
                 | Ok () ->
                     Http.Response.json ~request:req {|{"ok":true}|} reqd
                 | Error msg ->
                     Http.Response.json ~status:`Internal_server_error ~request:req
                       (Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)])) reqd)
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | _exn ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String "Invalid JSON body")])) reqd
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
         Http.Response.json ~compress:true ~request:req
           ~extra_headers:(Server_timing.extra_header timing)
           (Yojson.Safe.to_string json) reqd
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
         Http.Response.json ~compress:true ~request:req
           ~extra_headers:(Server_timing.extra_header timing)
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json ~state ~sw ~clock request in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution-trust" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_execution_trust_http_json ~state ~sw ~clock request
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/board" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_memory_http_json ~config:state.Mcp_server.room_config req
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
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
         let config = state.Mcp_server.room_config in
         let json =
           dashboard_memory_subsystems_http_json ~config
             ~include_memory_entries req
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       in
       if include_memory_entries then
         with_token_permission_auth ~permission:Masc_domain.CanReadState
           (fun state _agent_name req reqd -> handler state req reqd)
           request reqd
       else with_public_read handler request reqd)
  |> Http.Router.get "/api/v1/dashboard/doctor" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let self_bin = dashboard_doctor_self_bin () in
         (* /api/v1/dashboard/doctor previously fork-exec'd the server
            binary on every request and drained its JSON stdout
            synchronously on the Eio main domain.  Both costs (process
            spawn and the doctor scan itself) blocked every other HTTP
            fiber sharing the domain.  Cache the response per self_bin
            with stale-while-revalidate, and run the spawn on a worker
            domain via [Domain_pool_ref]. *)
         let cache_key = "dashboard.doctor:" ^ self_bin in
         let payload =
           Dashboard_cache.get_or_compute cache_key ~ttl:30.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               try
                 let buf, _status =
                   With_process.with_process_args_in
                     self_bin
                     [| self_bin; "doctor"; "all"; "--json" |]
                     (With_process.drain_to_buffer ~chunk:4096)
                 in
                 (* Parse so the cache stores a structured value rather than
                    a raw string; serialised back below. *)
                 try Yojson.Safe.from_string (Buffer.contents buf) with
                 | Yojson.Json_error _ ->
                   Yojson.Safe.from_string
                     (dashboard_doctor_degraded_json ~self_bin
                        ~exn:(Failure "doctor returned invalid JSON"))
               with
               | Eio.Cancel.Cancelled _ as exn -> raise exn
               | exn ->
                 Yojson.Safe.from_string
                   (dashboard_doctor_degraded_json ~self_bin ~exn)))
         in
         Http.Response.json
           ~compress:true
           ~request:req
           (Yojson.Safe.to_string payload)
           reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance/tool-events" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_governance_tool_events_http_json req in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_proof_http_json ~config:state.Mcp_server.room_config req
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/governance/approvals/resolve" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = state.Mcp_server.room_config.base_path in
             match dashboard_governance_approval_resolve_http_json ~base_path ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error (Gone _ as err) ->
                 respond_json_with_cors ~status:`Not_found request reqd
                   (Yojson.Safe.to_string
                      (operator_error_json (approval_resolve_http_error_to_string err)))
             | Error (Bad_request _ as err) ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (operator_error_json (approval_resolve_http_error_to_string err)))
           with Yojson.Json_error msg ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/governance/approvals/rules/delete" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = state.Mcp_server.room_config.base_path in
             match
               dashboard_governance_approval_rule_delete_http_json ~base_path ~args
             with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (operator_error_json message))
           with Yojson.Json_error msg ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
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
             state.Mcp_server.room_config.base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:2.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               operator_snapshot_http_json ~state ~sw ~clock req))
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/operator/digest" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match operator_digest_http_json ~state ~sw ~clock req with
         | Ok json ->
             Http.Response.json ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         | Error message ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (operator_error_json message))
       ) request reqd)
  |> Http.Router.post "/api/v1/operator/action" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_action" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_action_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error msg ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
         )
       ) request reqd)
  |> Http.Router.post "/api/v1/operator/confirm" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match operator_confirm_http_json ~state ~sw ~clock req ~args with
             | Ok json ->
                 respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string (operator_error_json message))
           with Yojson.Json_error msg ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
         )
       ) request reqd)

  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "planning:%s"
             state.Mcp_server.room_config.base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:5.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_planning_http_json ~config:state.Mcp_server.room_config))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
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
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "goals_tree:%s"
             state.Mcp_server.room_config.base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:5.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_goals_tree_http_json ~config:state.Mcp_server.room_config))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals/detail" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let goal_id =
           Server_utils.query_param req "goal_id"
           |> Option.map String.trim
           |> Option.value ~default:""
         in
         if goal_id = "" then
           respond_json_with_cors ~status:`Bad_request req reqd
             {|{"ok":false,"error":"goal_id query param is required"}|}
         else
           let cache_key =
             Printf.sprintf "goal_detail:%s:%s"
               state.Mcp_server.room_config.base_path goal_id
           in
           let json =
             Dashboard_cache.get_or_compute cache_key ~ttl:5.0 (fun () ->
               Domain_pool_ref.submit_io_or_inline (fun () ->
                 dashboard_goal_detail_http_json
                   ~config:state.Mcp_server.room_config ~goal_id))
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tasks/history" (fun request reqd ->
       with_public_read (fun state req reqd ->
         handle_dashboard_task_history state req reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "mission:%s" state.Mcp_server.room_config.base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:3.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_mission_http_json ~state ~sw ~clock req))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/session" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let cache_key =
           Printf.sprintf "session:%s" state.Mcp_server.room_config.base_path
         in
         let json =
           Dashboard_cache.get_or_compute cache_key ~ttl:3.0 (fun () ->
             Domain_pool_ref.submit_io_or_inline (fun () ->
               dashboard_session_http_json ~state ~sw ~clock req))
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
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
                    ~base_path:state.Mcp_server.room_config.base_path request)
               state.Mcp_server.room_config
           in
         Http.Response.json ~compress:true ~request:req
           ~extra_headers:(Server_timing.extra_header timing)
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_briefing_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/surface-readiness" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let surface_id = Server_utils.query_param req "surface_id" in
         let json = Dashboard_surface_readiness.json ?surface_id () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
         let json = Dashboard_http_tool_quality.aggregate ~n ?window_hours () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/keeper-feature-proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
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
              | Some value when Float.is_finite value ->
                Some (max 0.1 (min 168.0 value))
              | Some _ | None -> None)
           | None -> None
         in
         let success_threshold_pct =
           match Server_utils.query_param req "success_threshold_pct" with
           | Some s ->
             (match float_of_string_opt s with
              | Some value when Float.is_finite value ->
                Some (max 0.0 (min 100.0 value))
              | Some _ | None -> None)
           | None -> None
         in
         let config = state.Mcp_server.room_config in
         let json =
           Dashboard_keeper_feature_proof.json
             ~config ~n ?window_hours ?success_threshold_pct ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/transport-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_transport_health_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/perf" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_perf_http_json state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/harness-health" (fun _request reqd ->
       with_public_read (fun state req reqd ->
         let since = Server_utils.query_param req "since" in
         let until = Server_utils.query_param req "until" in
         let json =
           Dashboard_harness_health.json ~config:state.Mcp_server.room_config
             ?since ?until ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)
  |> Http.Router.get "/api/v1/dashboard/feature-health" (fun _request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_feature_health.json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)
  (* ── Eval feed (RFC-MASC-005 Phase 2) ── *)
  |> Http.Router.get "/api/v1/dashboard/eval-feed" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let agent_name = Server_utils.query_param req "agent_name" in
         let limit =
           Server_utils.int_query_param req "limit" ~default:10
           |> max 1 |> min 100
         in
         let json =
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
               ]
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
             ~timing state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req
           ~extra_headers:(Server_timing.extra_header timing)
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/oas/telemetry/recent" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = oas_telemetry_provider_param req in
         let limit = oas_telemetry_limit_param req in
         let json = Dashboard_oas_bridge.recent_json ?provider ~limit () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/oas/telemetry/summary" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let provider = oas_telemetry_provider_param req in
         let limit = oas_telemetry_limit_param req in
         let json = Dashboard_oas_bridge.summary_json ?provider ~limit () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
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
               state agent_name req reqd body_str))
         request reqd)

  |> Http.Router.post "/api/v1/keepers/chat/stream" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_keeper_msg" (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match parse_keeper_chat_stream_request body_str with
           | Ok payload ->
               handle_keeper_chat_stream ~sw ~clock state request reqd payload
           | Error message ->
               respond_json_with_cors ~status:`Bad_request request reqd
                 (Yojson.Safe.to_string (keeper_chat_stream_error_json message))
         )
       ) request reqd)

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
                 Keeper_api.handle_keeper_directive_post state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_unknown ->
           Http.Response.json ~status:`Not_found
             {|{"error":"not found"}|} reqd)

  (* ── Agent API routes (extracted) ── *)
  |> Server_dashboard_http_agent_api.add_agent_api_routes
  |> add_keeper_cascade_routes

and add_keeper_cascade_routes router =
  router
  (* ── Keeper cascade config API ──────────────────────────────── *)

  |> Http.Router.get "/api/v1/keeper/cascades" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let gate = cascade_profile_gate () in
         Http.Response.json ~request:request
           (Yojson.Safe.to_string (`Assoc [
             ("profiles", `List (List.map (fun s -> `String s) gate.valid_profiles));
             ( "invalid_profiles",
               `List
                 (List.map
                    (fun (name, errors) ->
                      `Assoc
                        [
                          ("name", `String name);
                          ("errors", `List (List.map (fun err -> `String err) errors));
                        ])
                    gate.invalid_profiles) );
           ])) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/keeper/cascade" (fun request reqd ->
       with_tool_auth
         ~tool_name:(Tool_name.Masc.to_string Tool_name.Masc.Status)
         (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           match Yojson.Safe.from_string body_str with
           | exception Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid JSON body"}|} reqd
           | json ->
             let keeper_name = Safe_ops.json_string_opt "keeper" json in
             let cascade_name = Safe_ops.json_string_opt "cascade_name" json in
             match keeper_name, cascade_name with
             | None, _ | _, None ->
               Http.Response.json ~status:`Bad_request ~request:req
                 {|{"ok":false,"error":"requires {\"keeper\":\"...\",\"cascade_name\":\"...\"}"}|}
                 reqd
             | Some name, Some cascade ->
               let known = available_cascade_profiles () in
               let invalid = invalid_cascade_assignment_profiles () in
               (match List.assoc_opt cascade invalid with
                | Some reasons ->
                  Http.Response.json ~status:`Conflict ~request:req
                    (Printf.sprintf
                       {|{"ok":false,"error":"cascade %s is invalid in active cascade.toml: %s"}|}
                       (String.escaped cascade)
                       (String.escaped (String.concat " | " reasons)))
                    reqd
                | None ->
               if not (List.mem cascade known) then
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Printf.sprintf
                     {|{"ok":false,"error":"unknown cascade %s. Available: %s"}|}
                     (String.escaped cascade)
                     (String.concat ", " known))
                   reqd
               else
               match Config_dir_resolver.keeper_toml_path_opt name with
               | None ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf
                     {|{"ok":false,"error":"no TOML config for keeper %s"}|}
                     (String.escaped name))
                   reqd
               | Some toml_path ->
                 match Keeper_toml_loader.update_keeper_toml_field
                         ~path:toml_path ~key:"cascade_name" ~value:cascade with
                 | Error e ->
                   Http.Response.json ~status:`Internal_server_error ~request:req
                     (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                       (String.escaped e))
                     reqd
                 | Ok () ->
                   let config = state.Mcp_server.room_config in
                   (match sync_keeper_cascade_meta ~config ~name
                            ~cascade_name:cascade with
                    | Error e ->
                      Http.Response.json ~status:`Internal_server_error ~request:req
                        (Printf.sprintf
                           {|{"ok":false,"error":"%s"}|}
                           (String.escaped e))
                        reqd
                    | Ok live_meta_synced ->
                      Http.Response.json ~request:req
                        (Yojson.Safe.to_string
                           (`Assoc
                              [
                                ("ok", `Bool true);
                                ("keeper", `String name);
                                ("cascade_name", `String cascade);
                                ("source", `String "toml");
                                ("live_meta_synced", `Bool live_meta_synced);
                              ]))
                        reqd))
         )
       ) request reqd)
