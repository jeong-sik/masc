
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

let add_routes ~sw ~clock router =
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
           dashboard_shell_http_json ?clock:state.Mcp_server.clock
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
  |> Http.Router.get "/api/v1/dashboard/room-truth" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_room_truth_http_json ~state ~sw ~clock req in
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
  |> Http.Router.get "/api/v1/dashboard/planning" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_planning_http_json req ~config:state.Mcp_server.room_config in
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
  |> Http.Router.get "/api/v1/dashboard/collaboration-evidence" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let session_id = Server_utils.query_param req "session_id" in
         let room_id = Server_utils.query_param req "room_id" in
         let json =
           Dashboard_collaboration_evidence.json ?session_id ?room_id
             ~config:state.Mcp_server.room_config ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/transport-health" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = dashboard_transport_health_http_json ~state in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/dashboard/harness-health" (fun _request reqd ->
       with_public_read (fun _state req reqd ->
         let since = Server_utils.query_param req "since" in
         let until = Server_utils.query_param req "until" in
         let json = Dashboard_harness_health.json ?since ?until () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)
  |> Http.Router.get "/api/v1/dashboard/feature-health" (fun _request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_feature_health.json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) _request reqd)

  (* ── Dashboard delete actions ── *)

  |> Http.Router.post "/api/v1/dashboard/board/delete" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "post_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
             | Some post_id ->
             match Board_dispatch.delete_post ~post_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"post not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"post_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/tasks/delete" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "task_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
             | Some task_id ->
             let config = state.Mcp_server.room_config in
             match Task_dispatch.delete_task config ~task_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error _ ->
                 Http.Response.json ~status:`Not_found ~request:req
                   {|{"ok":false,"error":"task not found or delete failed"}|} reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"task_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/dashboard/goals/delete" (fun request reqd ->
       with_public_read (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             match Safe_ops.json_string_opt "goal_id" json with
             | None ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
             | Some goal_id ->
             let config = state.Mcp_server.room_config in
             match Goal_store.delete_goal config ~goal_id with
             | Ok () ->
                 Http.Response.json ~compress:true ~request:req
                   {|{"ok":true}|} reqd
             | Error msg ->
                 Http.Response.json ~status:`Not_found ~request:req
                   (Printf.sprintf {|{"ok":false,"error":"%s"}|} (String.escaped msg))
                   reqd
           with Yojson.Json_error _ ->
             Http.Response.json ~status:`Bad_request ~request:req
               {|{"ok":false,"error":"invalid request: requires {\"goal_id\":\"...\"}"}|} reqd
         )
       ) request reqd)

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

  (* Keeper GET sub-routes: /config and /chat/history *)
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let req_path = Http.Request.path req in
         let prefix = "/api/v1/keepers/" in
         let plen = String.length prefix in
         let tlen = String.length req_path in
         let ends_with suffix =
           let slen = String.length suffix in
           tlen > plen + slen
           && String.sub req_path (tlen - slen) slen = suffix
         in
         let extract_name suffix =
           let slen = String.length suffix in
           String.trim (String.sub req_path plen (tlen - plen - slen))
         in
         if ends_with "/chat/history" then
           let name = extract_name "/chat/history" in
           if name = "" then
             respond_json_with_cors ~status:`Bad_request request reqd
               {|{"error":"missing keeper name"}|}
           else
             let base_dir = state.Mcp_server.room_config.base_path in
             let messages =
               Keeper_chat_store.load ~base_dir ~keeper_name:name
             in
             respond_json_with_cors ~status:`OK request reqd
               (Yojson.Safe.to_string (Keeper_chat_store.to_json_array messages))
         else if ends_with "/config" then
           let name = extract_name "/config" in
           if String.length name = 0 then
             Http.Response.json ~status:`Bad_request
               {|{"error":"keeper name is required"}|} reqd
           else
             let config = state.Mcp_server.room_config in
             let (st, json) =
               Dashboard_http_keeper.keeper_config_json config name
             in
             let status : Httpun.Status.t =
               match st with `OK -> `OK | `Not_found -> `Not_found
             in
             Http.Response.json ~status ~compress:true ~request:req
               (Yojson.Safe.to_string json) reqd
         else
           Http.Response.json ~status:`Not_found
             {|{"error":"not found"}|} reqd
       ) request reqd)

  (* Keeper config update — POST (PATCH semantic) to update an existing keeper
     with the same durable fields accepted by masc_keeper_up. *)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state agent_name req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           let req_path = Http.Request.path req in
           let prefix = "/api/v1/keepers/" in
           let suffix = "/config" in
           let plen = String.length prefix in
           let slen = String.length suffix in
           let tlen = String.length req_path in
           if tlen > plen + slen
              && String.sub req_path 0 plen = prefix
              && String.sub req_path (tlen - slen) slen = suffix
           then
             let name =
               String.trim
                 (String.sub req_path plen (tlen - plen - slen))
             in
             if String.length name = 0 then
               Http.Response.json ~status:`Bad_request
                 {|{"error":"keeper name is required"}|} reqd
             else
               let config = state.Mcp_server.room_config in
               match Keeper_types.read_meta config name with
               | Error msg ->
                   Http.Response.json ~status:`Not_found
                     (Printf.sprintf {|{"error":"%s"}|}
                        (String.escaped msg))
                     reqd
               | Ok None ->
                   Http.Response.json ~status:`Not_found
                     (Printf.sprintf {|{"error":"keeper %S not found"}|} name)
                     reqd
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
                            Http.Response.json ~status:`Bad_request
                              (Printf.sprintf
                                 {|{"error":"keeper name mismatch: route=%S body=%S"}|}
                                 name (Option.value ~default:"" body_name))
                              reqd
                          else
                            let args_with_name =
                              `Assoc (("name", `String name) :: List.remove_assoc "name" fields)
                            in
                            let keeper_ctx : _ Tool_keeper.context =
                              {
                                config;
                                agent_name;
                                sw;
                                clock;
                                proc_mgr = state.Mcp_server.proc_mgr;
                              }
                            in
                            (match Keeper_turn_up_args.parse keeper_ctx args_with_name with
                            | Error (_ok, msg) ->
                                Http.Response.json ~status:`Bad_request
                                  (Printf.sprintf {|{"error":"%s"}|}
                                     (String.escaped msg))
                                  reqd
                            | Ok parsed ->
                                let ok, msg =
                                  Keeper_turn_up_update.update_keeper keeper_ctx parsed meta0
                                in
                                if not ok then
                                  Http.Response.json ~status:`Bad_request
                                    (Printf.sprintf {|{"error":"%s"}|}
                                       (String.escaped msg))
                                    reqd
                                else
                                  let (_st, json) =
                                    Dashboard_http_keeper.keeper_config_json config name
                                  in
                                  Http.Response.json ~compress:true ~request:req
                                    (Yojson.Safe.to_string json) reqd)
                      | None ->
                          Http.Response.json ~status:`Bad_request
                            {|{"error":"request body must be a JSON object"}|}
                            reqd
                    with Yojson.Json_error e ->
                      Http.Response.json ~status:`Bad_request
                        (Printf.sprintf {|{"error":"invalid json: %s"}|}
                           (String.escaped e))
                        reqd)
           else
             Http.Response.json ~status:`Not_found
               {|{"error":"not found"}|} reqd
         )
       ) request reqd)

  (* Agent activity — per-agent tool call stats from telemetry *)
  |> Http.Router.get "/api/v1/agent-activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let hours =
           match Server_utils.query_param req "hours" with
           | Some h -> (try float_of_string h with Failure _ -> 24.0)
           | None -> 24.0
         in
         let since = Time_compat.now () -. (hours *. 3600.0) in
         let activities =
           Telemetry_eio.summarize_agent_activity state.Mcp_server.room_config ~since
         in
         let json = `Assoc [
           ("hours", `Float hours);
           ("agents", `List (List.map (fun (a : Telemetry_eio.agent_activity) ->
             `Assoc [
               ("agent_id", `String a.agent_id);
               ("tool_calls", `Int a.tool_calls);
               ("success_count", `Int a.success_count);
               ("failure_count", `Int a.failure_count);
               ("first_seen", `Float a.first_seen);
               ("last_seen", `Float a.last_seen);
             ]) activities));
         ] in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Tool metrics — unified registry stats for dashboard (P4 Phase 4.5) *)
  |> Http.Router.get "/api/v1/tool-metrics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Tool_unified.summary_report () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Agent timeline — per-agent activity timeline for Observatory detail *)
  |> Http.Router.get "/api/v1/agent-timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n when String.trim n <> "" -> String.trim n
           | _ -> ""
         in
         if agent_name = "" then
           Http.Response.json ~status:`Bad_request
             {|{"error":"agent_name query parameter is required"}|} reqd
         else
           let since_hours =
             match Server_utils.query_param req "since_hours" with
             | Some h -> (try float_of_string h with Failure _ -> 4.0)
             | None -> 4.0
           in
           let limit =
             match Server_utils.query_param req "limit" with
             | Some l -> (try int_of_string l with Failure _ -> 20)
             | None -> 20
           in
           let json =
             Tool_agent_timeline.build_timeline
               state.Mcp_server.room_config
               ~agent_name ~since_hours ~limit
               ~include_tasks:true ~include_board:false
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Agent relations — collaboration network + trust edges from Neo4j *)
  |> Http.Router.get "/api/v1/agent-relations" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n when String.trim n <> "" -> String.trim n
           | _ -> ""
         in
         if agent_name = "" then
           Http.Response.json ~status:`Bad_request
             {|{"error":"agent_name query parameter is required"}|} reqd
         else
           let json = Dashboard_agent_relations.json ~agent_name () in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/mdal/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         match mdal_loops_json ~config:state.Mcp_server.room_config req with
         | Ok json -> Http.Response.json (Yojson.Safe.to_string json) reqd
         | Error msg ->
             Http.Response.json ~status:`Bad_request
               (Yojson.Safe.to_string (mdal_loops_error_json msg)) reqd
       ) request reqd)

  (* Autoresearch loops list — all active + persisted loops *)
  |> Http.Router.get "/api/v1/autoresearch/loops" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json =
           Dashboard_http_autoresearch.autoresearch_loops_json ~base_path
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Autoresearch loop detail — single loop with full cycle history *)
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

  |> Http.Router.get "/api/v1/dashboard/repo-synthesis" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let limit =
           match Server_utils.query_param req "limit" with
           | Some raw -> (try int_of_string raw with Failure _ -> 20)
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
