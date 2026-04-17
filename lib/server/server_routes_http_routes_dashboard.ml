
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

let available_cascade_profiles () : string list =
  let config_path = Cascade_runtime.cascade_config_path () in
  match config_path with
  | None -> ["default"]
  | Some path ->
    (match Yojson.Safe.from_file path with
     | `Assoc fields ->
       let from_keys =
         List.filter_map (fun (k, _) ->
           if String.length k > 7
              && String.sub k (String.length k - 7) 7 = "_models"
           then Some (String.sub k 0 (String.length k - 7))
           else None
         ) fields
       in
       let with_default =
         if List.mem "default" from_keys then from_keys
         else "default" :: from_keys
       in
       List.sort_uniq String.compare with_default
     | _ -> ["default"]
     | exception Yojson.Json_error msg ->
       Log.Keeper.warn "cascade config parse error: %s" msg;
       ["default"]
     | exception Sys_error msg ->
       Log.Keeper.warn "cascade config read error: %s" msg;
       ["default"])

(** Broadcast handler: parse JSON body, extract "message" string field, and
    relay via Coord.broadcast.  Error responses are encoded through Yojson so
    exception messages cannot break JSON framing via embedded quotes. *)
let handle_broadcast state agent_name reqd body_str =
  let reply ok error_opt =
    let fields = [ ("ok", `Bool ok) ] in
    let fields = match error_opt with
      | Some msg -> fields @ [ ("error", `String msg) ]
      | None -> fields
    in
    Http.Response.json (Yojson.Safe.to_string (`Assoc fields)) reqd
  in
  try
    let json = Yojson.Safe.from_string body_str in
    match Yojson.Safe.Util.member "message" json with
    | `String message ->
        let config = state.Mcp_server.room_config in
        let _ = Coord.broadcast config ~from_agent:agent_name ~content:message in
        reply true None
    | `Null -> reply false (Some "missing required field: message")
    | _ -> reply false (Some "field 'message' must be a string")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Yojson.Json_error msg -> reply false (Some ("invalid JSON: " ^ msg))
  | e -> reply false (Some (Printexc.to_string e))

let handle_dashboard_link_previews state req reqd body_str =
  let respond_error message =
    Http.Response.json ~status:`Bad_request ~request:req
      (Yojson.Safe.to_string
         (`Assoc
           [
             ("ok", `Bool false);
             ("error", `String message);
           ]))
      reqd
  in
  try
    let args = Yojson.Safe.from_string body_str in
    match
      Server_dashboard_http_link_preview.dashboard_link_previews_http_json
        ~state ~args
    with
    | Ok json ->
        Http.Response.json ~compress:true ~request:req
          (Yojson.Safe.to_string json) reqd
    | Error message -> respond_error message
  with Yojson.Json_error message ->
    respond_error ("invalid json: " ^ message)

let handle_dashboard_task_history state req reqd =
  let task_id =
    match Server_utils.query_param req "task_id" with
    | Some value -> String.trim value
    | None -> ""
  in
  if task_id = "" then
    Http.Response.json ~status:`Bad_request ~request:req
      {|{"error":"task_id is required"}|} reqd
  else
    let limit =
      Server_utils.int_query_param req "limit" ~default:50
      |> Server_utils.clamp ~min_v:1 ~max_v:200
    in
    let json =
      Tool_task.task_history_events_json state.Mcp_server.room_config ~task_id ~limit
    in
    Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd

let rec add_routes ~sw ~clock router =
  router
  |> Http.Router.post "/api/v1/broadcast" (fun request reqd ->
       (* POST /api/v1/broadcast - HTTP API for external tools like autocov *)
       with_token_permission_auth ~permission:Types.CanBroadcast
         (fun state agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           handle_broadcast state agent_name reqd body_str
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_token_permission_auth ~permission:Types.CanBroadcast
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
         let json =
           dashboard_shell_http_json ?clock:state.Mcp_server.clock ~request:req
             state.Mcp_server.room_config
         in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/runtime-probe" (fun request reqd ->
       let force = Server_utils.bool_query_param request "force" ~default:false in
       let handle _state req reqd =
         let json = dashboard_runtime_probe_http_json ~force () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       in
       with_tool_auth ~tool_name:"masc_runtime_ollama_probe" handle request reqd)
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
       with_tool_auth ~tool_name:"masc_broadcast" (fun state req reqd ->
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
  |> Http.Router.post "/api/v1/dashboard/link-previews" (fun request reqd ->
       with_permission_auth ~permission:Types.CanReadState
         (fun state req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             handle_dashboard_link_previews state req reqd body_str))
         request reqd)
  |> Http.Router.get "/api/v1/dashboard/memory-subsystems" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let json = dashboard_memory_subsystems_http_json ~config req in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
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

  (* Operator surface restored after cp-purge (#7349): handlers existed in
     server_dashboard_http_core/.ml but their Router.get/post registrations
     were deleted together with the Command Plane. Dashboard SSE hydrates
     the same caches, so this path only services HTTP fallbacks (first load
     before SSE attaches + explicit tab-refresh). *)
  |> Http.Router.get "/api/v1/operator" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = operator_snapshot_http_json ~state ~sw ~clock req in
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
         let json = dashboard_planning_http_json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/goals" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_goals_tree_http_json ~config:state.Mcp_server.room_config in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/tasks/history" (fun request reqd ->
       with_public_read (fun state req reqd ->
         handle_dashboard_task_history state req reqd
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
         let window_hours =
           match Server_utils.query_param req "window_hours" with
           | Some s ->
             (try
                let value = float_of_string s in
                Some (max 0.1 (min 168.0 value))
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | _ -> None)
           | None -> None
         in
         let json = Dashboard_http_tool_quality.aggregate ~n ?window_hours () in
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
                 ("generated_at", `String (Types.now_iso ()));
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
                 ("generated_at", `String (Types.now_iso ()));
                 ("agent_count", `Int (List.length agents));
                 ("agents", `List per_agent);
               ]
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* ── Telemetry unified view ── *)
  |> Http.Router.get "/api/v1/dashboard/telemetry" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let base_path = config.base_path in
         let masc_root = Coord.masc_root_dir config in
         let float_query_param req key =
           match Server_utils.query_param req key with
           | None -> None
           | Some raw -> float_of_string_opt raw
         in
         let keeper_name = Server_utils.query_param req "keeper" in
         let session_id = Server_utils.query_param req "session_id" in
         let operation_id = Server_utils.query_param req "operation_id" in
         let worker_run_id = Server_utils.query_param req "worker_run_id" in
         let since_ts = Option.map (fun ms -> ms /. 1000.0)
             (float_query_param req "since_ms")
         in
         let until_ts = Option.map (fun ms -> ms /. 1000.0)
             (float_query_param req "until_ms")
         in
         let has_time_window = Option.is_some since_ts || Option.is_some until_ts in
         let n =
           match Server_utils.query_param req "n" with
           | Some raw ->
             Option.value ~default:(if has_time_window then 0 else 100)
               (int_of_string_opt raw)
             |> max 0
           | None -> if has_time_window then 0 else 100
         in
         let sources =
           match Server_utils.query_param req "source" with
           | None -> Telemetry_unified.all_sources
           | Some s ->
             (match Telemetry_unified.source_of_string s with
              | Some src -> [src]
              | None -> Telemetry_unified.all_sources)
         in
         let result =
           Telemetry_unified.read_unified_result ~base_path ~masc_root ~sources
             ?keeper_name ?session_id ?operation_id ?worker_run_id
             ?since_ts ?until_ts ~n ()
         in
         let json = `Assoc [
           ("generated_at", `String (Types.now_iso ()));
           ("count", `Int (List.length result.entries));
           ("total_matching_entries", `Int result.total_matching_entries);
           ("truncated", `Bool result.truncated);
           ("entries", `List result.entries);
         ] in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/telemetry/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let base_path = config.base_path in
         let masc_root = Coord.masc_root_dir config in
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
       if Keeper_api.is_keeper_checkpoints_get_path (Http.Request.path request) then
         with_token_permission_auth ~permission:Types.CanAdmin
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
       | Keeper_api.Keeper_post_reset ->
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state agent_name req reqd ->
               Keeper_api.handle_keeper_lifecycle_post ~sw ~clock ~tool_name:"masc_keeper_reset"
                 ~action:"reset" state agent_name req reqd
             ) request reqd
       | Keeper_api.Keeper_post_clear ->
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_lifecycle_post ~body_str ~sw ~clock
                   ~tool_name:"masc_keeper_clear" ~action:"clear"
                   state agent_name req reqd
               )
             ) request reqd
       | Keeper_api.Keeper_post_checkpoints ->
           with_token_permission_auth ~permission:Types.CanAdmin
             (fun state _agent_name req reqd ->
               Http.Request.read_body_async reqd (fun body_str ->
                 Keeper_api.handle_keeper_checkpoints_post state req reqd body_str
               )
             ) request reqd
       | Keeper_api.Keeper_post_directive ->
           with_token_permission_auth ~permission:Types.CanAdmin
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
  |> add_autoresearch_routes

(* ── Autoresearch routes ───────────────────────────────────────── *)

and add_autoresearch_routes router =
  router
  (* Autoresearch loops list -- all active + persisted loops *)
  |> Http.Router.get "/api/v1/autoresearch/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let offset =
           Server_utils.int_query_param req "offset" ~default:0
           |> Server_utils.clamp ~min_v:0 ~max_v:1000000
         in
         let limit =
           Server_utils.int_query_param req "limit" ~default:100
           |> Server_utils.clamp ~min_v:1 ~max_v:1000
         in
         let json =
           Dashboard_http_autoresearch.autoresearch_loops_json ~base_path ~offset ~limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Autoresearch loops CSV export *)
  |> Http.Router.get "/api/v1/autoresearch/loops/csv" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let csv = Dashboard_http_autoresearch.autoresearch_loops_csv ~base_path in
         let headers =
           Httpun.Headers.of_list
             [
               ("content-type", "text/csv; charset=utf-8");
               ("content-disposition", "attachment; filename=\"autoresearch_loops.csv\"");
             ]
         in
         let response = Httpun.Response.create ~headers `OK in
         Httpun.Reqd.respond_with_string reqd response csv
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
                   Dashboard_http_autoresearch.delete_loop_json ~base_path ~loop_id ~requester_agent:(agent_from_request request)
                 with                 | Ok result ->
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

  (* ── Keeper cascade config API ──────────────────────────────── *)

  |> Http.Router.get "/api/v1/keeper/cascades" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let profiles = available_cascade_profiles () in
         Http.Response.json ~request:request
           (Yojson.Safe.to_string (`Assoc [
             ("profiles", `List (List.map (fun s -> `String s) profiles));
           ])) reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/keeper/cascade" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_status" (fun _state req reqd ->
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
                   Http.Response.json ~request:req
                     (Printf.sprintf
                       {|{"ok":true,"keeper":"%s","cascade_name":"%s","source":"toml"}|}
                       (String.escaped name) (String.escaped cascade))
                     reqd
         )
       ) request reqd)
