(** Agent API HTTP handlers — activity, tool-metrics, timeline, relations.

    Extracted from server_routes_http_routes_dashboard.ml.
    Contains GET handler logic for /api/v1/agent-activity,
    /api/v1/tool-metrics, /api/v1/agent-timeline, /api/v1/agent-relations. *)

module Http = Http_server_eio

open Server_auth

let add_agent_api_routes router =
  router
  (* Agent activity -- per-agent tool call stats from telemetry *)
  |> Http.Router.get "/api/v1/agent-activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let hours =
           match Server_utils.query_param req "hours" with
           | Some h -> Option.value ~default:24.0 (float_of_string_opt h)
           | None -> 24.0
         in
         let since = Time_compat.now () -. (hours *. Masc_time_constants.hour) in
         let activities =
           Telemetry_eio.summarize_agent_activity (Mcp_server.workspace_config state) ~since
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
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Tool metrics -- unified registry stats for dashboard *)
  |> Http.Router.get "/api/v1/tool-metrics" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json =
           Tool_unified.summary_report
             ~runtime_metrics:Runtime_observation.runtime_metrics_json
             ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Agent timeline -- per-agent activity timeline for Observatory detail *)
  |> Http.Router.get "/api/v1/agent-timeline" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n ->
               let trimmed = String.trim n in
               if trimmed <> "" then trimmed else ""
           | None -> ""
         in
         if agent_name = "" then
           Http.Response.json_value ~status:`Bad_request
             (`Assoc
                [
                  ( "error",
                    `String "agent_name query parameter is required" );
                ])
             reqd
         else
           let since_hours =
             match Server_utils.query_param req "since_hours" with
             | Some h -> Option.value ~default:4.0 (float_of_string_opt h)
             | None -> 4.0
           in
           let limit =
             match Server_utils.query_param req "limit" with
             | Some l -> (Option.value ~default:20 (int_of_string_opt l))
             | None -> 20
           in
           let json =
             let config = Mcp_server.workspace_config state in
             Tool_agent_timeline.build_timeline
               ~load_chat:(fun ~agent_name ->
                 Keeper_chat_timeline_source.lines_for
                   ~base_dir:config.base_path ~keeper_name:agent_name)
               config
               ~agent_name ~since_hours ~limit
               ~include_tasks:true ~include_board:false
               ~include_tool_calls:true
           in
          Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)

  (* Agent relations -- collaboration network + trust edges *)
  |> Http.Router.get "/api/v1/agent-relations" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let agent_name =
           match Server_utils.query_param req "agent_name" with
           | Some n ->
               let trimmed = String.trim n in
               if trimmed <> "" then trimmed else ""
           | None -> ""
         in
         if agent_name = "" then
           Http.Response.json_value ~status:`Bad_request
             (`Assoc
                [
                  ( "error",
                    `String "agent_name query parameter is required" );
                ])
             reqd
         else
           let json = Dashboard_agent_relations.json ~agent_name () in
          Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
