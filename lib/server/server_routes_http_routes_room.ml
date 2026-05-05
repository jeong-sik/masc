
open Masc_domain
open Server_utils
open Server_auth
open Server_routes_http_common

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

  let add_routes router =
  router
  |> Http.Router.get "/api/v1/status" (fun request reqd ->
       with_read_auth (fun state _req reqd ->
         let config = state.Mcp_server.room_config in
         let status = Room_protocol.status config in
         let json = `Assoc [
           ("cluster", `String status.cluster);
           ("project", `String status.project);
           ("tempo_interval_s", `Float status.tempo_interval_s);
           ("paused", `Bool status.paused);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/tasks" (fun request reqd ->
       with_read_auth (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let include_done = bool_query_param req "include_done" ~default:false in
         let include_cancelled = bool_query_param req "include_cancelled" ~default:false in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let filtered =
           Room_protocol.tasks ?status_filter ~include_done
             ~include_cancelled config
         in
         let total = List.length filtered in
         let page =
           filtered
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let tasks_json = List.map (fun (t : Masc_domain.task) ->
           let base_fields =
             [
               ("id", `String t.id);
               ("title", `String t.title);
               ("description", `String t.description);
               ("status", `String (Masc_domain.string_of_task_status t.task_status));
               ("priority", `Int t.priority);
               ( "assignee",
                 Json_util.string_opt_to_json
                   (Room_protocol.task_assignee t) );
               ("created_at", `String t.created_at);
             ]
           in
           let projection_fields =
             (* Task_contract_gate removed *)
             ignore (config, t);
             []
           in
           `Assoc (base_fields @ projection_fields)
         ) page in
         let json = `Assoc [
           ("tasks", `List tasks_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/agents" (fun request reqd ->
       with_read_auth (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let status_filter = query_param req "status" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let agents =
           Room_protocol.agents ?status_filter config
         in
         let total = List.length agents in
         let page =
           agents
           |> List.filteri (fun idx _ -> idx >= offset && idx < offset + limit)
         in
         let agents_json = List.map (fun (a : Masc_domain.agent) ->
           let profile = Dashboard_execution_helpers.get_agent_profile a.name in
           `Assoc [
             ("name", `String a.name);
             ("status", `String (Masc_domain.string_of_agent_status a.status));
             ("current_task", Json_util.string_opt_to_json a.current_task);
             ("emoji", `String profile.emoji);
             ("koreanName", `String profile.korean_name);
             ("model", Json_util.string_opt_to_json profile.model);
             ("traits", `List (List.map (fun t -> `String t) profile.traits));
             ("interests", `List (List.map (fun i -> `String i) profile.interests));
           ]
         ) page in
         let json = `Assoc [
           ("agents", `List agents_json);
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/messages" (fun request reqd ->
       with_read_auth (fun state req reqd ->
         let config = state.Mcp_server.room_config in
         let since_seq = int_query_param req "since_seq" ~default:0 in
         let limit = int_query_param req "limit" ~default:20 in
         let agent_filter = query_param req "agent" in
         let filtered =
           Room_protocol.messages ?agent_filter ~since_seq ~limit:500 config
         in
         let total = List.length filtered in
         let page = filtered |> List.filteri (fun idx _ -> idx < limit) in
         let msgs_json = List.map (fun (m : Masc_domain.message) ->
           `Assoc [
             ("from", `String m.from_agent);
             ("content", `String m.content);
             ("timestamp", `String m.timestamp);
             ("seq", `Int m.seq);
           ]
         ) page in
         let json = `Assoc [
           ("messages", `List msgs_json);
           ("limit", `Int limit);
           ("since_seq", `Int since_seq);
           ("total", `Int total);
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
