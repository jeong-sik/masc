
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
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
             Http.Response.json
               (Printf.sprintf {|{"ok":false,"error":"%s"}|} (Printexc.to_string e))
               reqd
         )
       ) request reqd)
  |> Http.Router.post "/broadcast" (fun request reqd ->
       (* POST /broadcast - Alias for autocov compatibility *)
       with_read_auth (fun state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let json = Yojson.Safe.from_string body_str in
             let agent_name = json |> Yojson.Safe.Util.member "agent_name" |> Yojson.Safe.Util.to_string in
             let message = json |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
             let config = state.Mcp_server.room_config in
             let _ = Room.broadcast config ~from_agent:agent_name ~content:message in
             Http.Response.json {|{"ok":true}|} reqd
           with e ->
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
         let json = dashboard_shell_http_json state.Mcp_server.room_config in
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
  (* Legacy alias — kept for backward compatibility *)
  |> Http.Router.get "/api/v1/dashboard/memory" (fun request reqd ->
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
  |> Http.Router.get "/api/v1/dashboard/semantics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = dashboard_semantics_http_json () in
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

  (* Keeper config — structured read-only config view for a single keeper *)
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       with_public_read (fun state req reqd ->
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

  (* Agent activity — per-agent tool call stats from telemetry *)
  |> Http.Router.get "/api/v1/agent-activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let hours =
           match Server_utils.query_param req "hours" with
           | Some h -> (try float_of_string h with _ -> 24.0)
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
             | Some h -> (try float_of_string h with _ -> 4.0)
             | None -> 4.0
           in
           let limit =
             match Server_utils.query_param req "limit" with
             | Some l -> (try int_of_string l with _ -> 20)
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
