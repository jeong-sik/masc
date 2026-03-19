[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_dashboard_http
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime
open Server_routes_http_keeper_stream

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Server_social_http = Server_social_http
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let social_http_deps : Server_social_http.deps =
  {
    query_param;
    int_query_param;
    get_origin;
    cors_headers;
    get_switch = (fun () -> Some (Eio_context.get_switch ()));
    get_clock = (fun () -> Some (Eio_context.get_clock ()));
    get_session_id_any = Server_mcp_transport_http.get_session_id_any;
  }

let social_events_http_json ~state request =
  Server_social_http.events_http_json ~deps:social_http_deps ~state request

let social_graph_http_json ~state request =
  Server_social_http.graph_http_json ~deps:social_http_deps ~state request

let social_events_stream_http ~state request reqd =
  Server_social_http.handle_stream ~deps:social_http_deps ~state request reqd

let add_routes router =
  router
  |> Http.Router.get "/api/v1/events" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = social_events_http_json ~state req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/events/stream" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         social_events_stream_http ~state request reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/social-graph" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let json = social_graph_http_json ~state req in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/governance/cases" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let json = governance_cases_json req ~base_path in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.prefix_get "/api/v1/governance/cases/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/governance/cases/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "case_id is required")]))
                ~status:`Bad_request reqd
          | Some case_id ->
              let (status, json) = governance_case_detail_json ~base_path ~case_id in
              respond_json_with_cors ~status request reqd (Yojson.Safe.to_string json))
       ) request reqd)

  |> Http.Router.get "/api/v1/governance/feed" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let filter = query_param req "filter" |> Option.value ~default:"decisions" in
         let limit = int_query_param req "limit" ~default:20 |> clamp ~min_v:1 ~max_v:100 in
         let ctx : Tool_council.context =
           { base_path; agent_name = "http-api"; room_config = None }
         in
         let args = `Assoc [
           ("filter", `String filter);
           ("limit", `Int limit);
         ] in
         let (_ok, body) = Tool_council.handle_governance_feed ctx args in
         Http.Response.json body reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/governance/params" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let args = `Assoc [] in
         let ctx : Tool_council.context =
           { base_path = ""; agent_name = "http-api"; room_config = None }
         in
         let (_ok, body) = Tool_council.handle_runtime_params ctx args in
         Http.Response.json body reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let hearth = query_param req "hearth" in
         let sort_by = board_sort_order_of_request req in
         let exclude_system = bool_query_param req "exclude_system" ~default:false in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let offset = int_query_param req "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
         let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
         let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
         let posts = filter_board_posts ~exclude_system posts in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           try List.assoc author karma_map with Not_found -> 0
         in
         let paged = posts |> drop offset |> take limit in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
               let author = Board.Agent_id.to_string p.author in
               board_post_dashboard_json ~author_karma:(get_karma author) p)
             paged
         in
         let json = `Assoc [
           ("posts", `List posts_json);
           ("count", `Int (List.length posts_json));
           ("limit", `Int limit);
           ("offset", `Int offset);
           ("sort_by", `String (board_sort_label sort_by));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/hearths" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let hearths = Board_dispatch.list_hearths () in
         let json = `Assoc [
           ("hearths", `List (List.map (fun (name, count) ->
             `Assoc [("name", `String name); ("count", `Int count)]
           ) hearths));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/board/flairs" (fun _request reqd ->
       let flairs = List.map Board.flair_to_yojson Board.available_flairs in
       let json = `Assoc [("flairs", `List flairs)] in
       Http.Response.json (Yojson.Safe.to_string json) reqd)


  (* Board write APIs — used by Bevy Viewer *)
  |> Http.Router.post "/api/v1/tools/masc_board_vote" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_vote" args in
             let status = if ok then `OK else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)

  |> Http.Router.post "/api/v1/tools/masc_board_comment" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let (ok, msg) = Tool_board.handle_tool "masc_board_comment" args in
             let status = if ok then `Created else `Bad_request in
             respond_json_with_cors ~status request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool ok); ("message", `String msg)
               ]))
           with exn ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string (`Assoc [
                 ("ok", `Bool false);
                 ("message", `String (Printexc.to_string exn))
               ]))
         )
       ) request reqd)
  |> Http.Router.get "/api/v1/karma" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let karma_list = Board_dispatch.get_all_karma () in
         let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
         let json = `Assoc [
           ("karma", `List (List.map (fun (agent, k) ->
             `Assoc [("agent", `String agent); ("karma", `Int k)]
           ) sorted));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Mention Inbox API *)
  |> Http.Router.prefix_get "/api/v1/mentions/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/mentions/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "agent_name is required")]))
                ~status:`Bad_request reqd
          | Some agent_name ->
              let limit = standard_limit request in
              let mentions =
                Mention_inbox.read_mentions state.Mcp_server.room_config
                  ~target_agent:agent_name ~limit
              in
              let unread =
                Mention_inbox.unread_count state.Mcp_server.room_config
                  ~target_agent:agent_name
              in
              let json = `Assoc [
                ("agent", `String agent_name);
                ("unread_count", `Int unread);
                ("mentions", `List (List.map Mention_inbox.mention_record_to_json mentions));
              ] in
              Http.Response.json (Yojson.Safe.to_string json) reqd)
       ) request reqd)

  (* Agent Reputation API *)
  |> Http.Router.prefix_get "/api/v1/reputation/" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         let path = Http.Request.path request in
         (match extract_path_param ~prefix:"/api/v1/reputation/" path with
          | None ->
              Http.Response.json
                (Yojson.Safe.to_string (`Assoc [("error", `String "agent_name is required")]))
                ~status:`Bad_request reqd
          | Some agent_name ->
              let rep =
                Agent_reputation.compute_reputation
                  state.Mcp_server.room_config ~agent_name
              in
              Http.Response.json
                (Yojson.Safe.to_string (Agent_reputation.reputation_to_json rep))
                reqd)
       ) request reqd)

  (* Activity Feed API *)
  |> Http.Router.get "/api/v1/activity" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let agent_name = query_param req "agent" in
         let limit = int_query_param req "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
         let items =
           Activity_feed.recent_activity state.Mcp_server.room_config
             ?agent_name ~limit ()
         in
         let json = `Assoc [
           ("items", `List (List.map Activity_feed.activity_item_to_json items));
           ("count", `Int (List.length items));
         ] in
         Http.Response.json (Yojson.Safe.to_string json) reqd
       ) request reqd)

  (* Lodge Agents REST API removed -- Lodge heartbeat deprecated (#1596) *)
