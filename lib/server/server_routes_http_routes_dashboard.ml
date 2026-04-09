
open Server_auth
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream
module Keeper_api = Server_dashboard_http_keeper_api

let rec add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_token_permission_auth ~permission:Types.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_token_permission_auth ~permission:Types.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
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
         let json =
           dashboard_shell_http_json ?clock:state.Mcp_server.clock ~request:req
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/logs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit =
           Server_utils.int_query_param req "limit" ~default:200
           |> max 1 |> min 3000
         in
         let min_level = match Server_utils.query_param req "level" with
           | Some v -> Log.level_to_int (Log.level_of_string v)
           | None -> 0
         in
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
         let json = Log.Ring.to_json entries in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/logs/tool-host-failures" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let fallback_agent = agent_from_request request in
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
  |> Http.Router.get "/api/v1/dashboard/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Env_config_introspect.to_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let patterns = Anti_rationalization.load_excuse_patterns () in
         let json_items = List.map (fun (pat, reason) -> `List [`String pat; `String reason]) patterns in
         let json = `List json_items in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/config/excuse-patterns" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
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
  |> Http.Router.get "/api/v1/dashboard/namespace-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_namespace_truth_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/room-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_namespace_truth_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/execution" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_execution_http_json ~state ~sw ~clock request in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_memory_http_json req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/governance" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = dashboard_governance_http_json req ~base_path in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/dashboard/governance/approvals/resolve" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_operator_confirm" (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             match dashboard_governance_approval_resolve_http_json ~args with
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
         let json = dashboard_planning_http_json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_goals_tree_http_json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/session" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_session_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tools" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json =
           dashboard_tools_http_json
             ?actor:(agent_from_request request)
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/mission/briefing" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_mission_briefing_http_json ~state ~sw ~clock req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/proof" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_proof_http_json ~state req in
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
             | Some s -> (try int_of_string s with Eio.Cancel.Cancelled _ as e -> raise e | _ -> 5000)
             | None -> 5000
           in
           max 1 (min 50000 raw)
         in
         let json = Dashboard_http_tool_quality.aggregate ~n () in
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

  (* ── Telemetry unified view ── *)
  |> Http.Router.get "/api/v1/dashboard/telemetry" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let base_path = config.base_path in
         let masc_root = Room.masc_root_dir config in
         let n =
           Server_utils.int_query_param req "n" ~default:100
           |> max 1 |> min 500
         in
         let keeper_name = Server_utils.query_param req "keeper" in
         let sources =
           match Server_utils.query_param req "source" with
           | None -> Telemetry_unified.all_sources
           | Some s ->
             (match Telemetry_unified.source_of_string s with
              | Some src -> [src]
              | None -> Telemetry_unified.all_sources)
         in
         let entries =
           Telemetry_unified.read_unified ~base_path ~masc_root ~sources
             ?keeper_name ~n ()
         in
         let json = `Assoc [
           ("generated_at", `String (Types.now_iso ()));
           ("count", `Int (List.length entries));
           ("entries", `List entries);
         ] in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/telemetry/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let base_path = config.base_path in
         let masc_root = Room.masc_root_dir config in
         let json = Telemetry_unified.summary_json ~base_path ~masc_root () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* ── Dashboard delete actions (extracted) ── *)
  |> Server_dashboard_http_delete_actions.add_delete_action_routes

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
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_config_post ~sw ~clock state agent_name req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_boot ->
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_up"
                 ~action:"boot" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_shutdown ->
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_down"
                 ~action:"shutdown" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_unknown ->
           Http.Response.json ~status:`Not_found
             {|{"error":"not found"}|} reqd)

  (* ── Agent API routes (extracted) ── *)
  |> Server_dashboard_http_agent_api.add_agent_api_routes
  |> add_autoresearch_routes
  |> add_repo_synthesis_routes

(* ── Autoresearch routes ───────────────────────────────────────── *)

and add_autoresearch_routes router =
  router
  (* Autoresearch loops list -- all active + persisted loops *)
  |> Http.Router.get "/api/v1/autoresearch/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json =
           Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Autoresearch loop detail -- single loop with full cycle history *)
  |> Http.Router.prefix_get "/api/v1/autoresearch/loops/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/autoresearch/loops/" in
         let loop_id =
           String.trim
             (String.sub req_path (String.length prefix)
                (String.length req_path - String.length prefix))
         in
         if String.length loop_id = 0 then
           Http.Response.json ~status:`Bad_request
             {|{"error":"loop_id is required"}|} reqd
         else
           let history_limit =
             Server_utils.int_query_param req "history_limit" ~default:100
             |> Server_utils.clamp ~min_v:0 ~max_v:1000
           in
           match
             Dashboard_http_autoresearch.autoresearch_loop_detail_json
               ~base_path ~loop_id ~history_limit
           with
           | Ok json ->
               Http.Response.json ~compress:true ~request:req
                 (Yojson.Safe.to_string json) reqd
           | Error msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                 reqd
           | exception Invalid_argument msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
               reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/retry" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_stop" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "loop_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
                   reqd
             | Some loop_id ->
             let base_path = state.Mcp_server.room_config.base_path in
             (match Dashboard_http_autoresearch.validate_loop_id loop_id with
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped message))
                   reqd
             | Ok () -> (
                 match
                   Dashboard_http_autoresearch.retry_loop_json ~base_path ~loop_id
                 with
                 | Ok result ->
                     Http.Response.json ~compress:true ~request:req
                       (Yojson.Safe.to_string result) reqd
                 | Error message ->
                     Http.Response.json ~status:`Bad_request ~request:req
                       (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                          (String.escaped message))
                       reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
               reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/start" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_start" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let base_path = state.Mcp_server.room_config.base_path in
             (match
               Dashboard_http_autoresearch.start_loop_json ~base_path ~args
             with
             | Ok result ->
                 Http.Response.json ~compress:true ~request:req
                   (Yojson.Safe.to_string result) reqd
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc [("ok", `Bool false); ("error", `String message)]))
                   reqd)
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid JSON body"}|}
               reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/autoresearch/loops/delete" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_autoresearch_stop" (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "loop_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
                   reqd
             | Some loop_id ->
             let base_path = state.Mcp_server.room_config.base_path in
             (match Dashboard_http_autoresearch.validate_loop_id loop_id with
             | Error message ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                      (String.escaped message))
                   reqd
             | Ok () -> (
                 match
                   Dashboard_http_autoresearch.delete_loop_json ~base_path ~loop_id
                 with
                 | Ok result ->
                     Http.Response.json ~compress:true ~request:req
                       (Yojson.Safe.to_string result) reqd
                 | Error message ->
                     Http.Response.json ~status:`Not_found ~request:req
                       (Printf.sprintf {|{"ok":false,"error":"%s"}|}
                          (String.escaped message))
                       reqd))
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"loop_id\":\"...\"}"}|}
               reqd
         )
       ) request reqd)

(* ── Repo synthesis routes ─────────────────────────────────────── *)

and add_repo_synthesis_routes router =
  router
  |> Http.Router.get "/api/v1/dashboard/repo-synthesis" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let limit =
           match Server_utils.query_param req "limit" with
           | Some raw -> (Option.value ~default:20 (int_of_string_opt raw))
           | None -> 20
         in
         let json =
           Dashboard_http_repo_synthesis.repo_synthesis_benchmarks_json
             ~base_path ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.prefix_get "/api/v1/repo-synthesis/benchmarks/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/repo-synthesis/benchmarks/" in
         let run_id =
           String.trim
             (String.sub req_path (String.length prefix)
                (String.length req_path - String.length prefix))
         in
         if String.length run_id = 0 then
           Http.Response.json ~status:`Bad_request
             {|{"error":"run_id is required"}|} reqd
         else
           match
             Dashboard_http_repo_synthesis.repo_synthesis_benchmark_detail_json
               ~base_path ~run_id
           with
           | Ok json ->
               Http.Response.json ~compress:true ~request:req
                 (Yojson.Safe.to_string json) reqd
           | Error msg ->
               Http.Response.json ~status:`Not_found
                 (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                 reqd
       ) request reqd)
