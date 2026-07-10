
open Server_auth
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime
open Server_voice_config

module Http = Http_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let respond_redirect ~location reqd =
  let response =
    Httpun.Response.create
      ~headers:(Httpun.Headers.of_list [
        ("location", location);
        ("content-length", "0");
      ])
      `Found
  in
  Httpun.Reqd.respond_with_string reqd response ""

let canonical_loopback_location ~default_port request =
  let (host, port) =
    parse_host_port
      (Httpun.Headers.get request.Httpun.Request.headers "host")
      (Env_config_core.masc_host ()) default_port
  in
  let canonical_host = Transport_read_model.normalize_advertised_host host in
  if String.equal canonical_host host then
    None
  else
    Some (Printf.sprintf "http://%s:%d%s" canonical_host port request.target)

let canonical_root_dashboard_location ~default_port request =
  let (host, port) =
    parse_host_port
      (Httpun.Headers.get request.Httpun.Request.headers "host")
      (Env_config_core.masc_host ()) default_port
  in
  let canonical_host = Transport_read_model.normalize_advertised_host host in
  if String.equal canonical_host host then
    None
  else
    Some (Printf.sprintf "http://%s:%d/dashboard" canonical_host port)

let with_canonical_loopback_host ~port handler request reqd =
  match canonical_loopback_location ~default_port:port request with
  | Some location -> respond_redirect ~location reqd
  | None -> handler request reqd

let redirect_to_dashboard reqd =
  respond_redirect ~location:"/dashboard" reqd

let websocket_discovery_handler request reqd =
  Http.Response.json_value (websocket_discovery_json request) reqd

let header_contains_token request name token =
  match Httpun.Headers.get request.Httpun.Request.headers name with
  | None -> false
  | Some raw ->
      raw
      |> String.split_on_char ','
      |> List.exists (fun part ->
           String.equal
             (String.lowercase_ascii (String.trim part))
             token)

let header_equals request name expected =
  match Httpun.Headers.get request.Httpun.Request.headers name with
  | None -> false
  | Some raw ->
      String.equal
        (String.lowercase_ascii (String.trim raw))
        expected

let is_websocket_upgrade_request request =
  request.Httpun.Request.meth = `GET
  && header_contains_token request "connection" "upgrade"
  && header_equals request "upgrade" "websocket"

let websocket_upgrade_unavailable_reason () =
  if not (Transport_metrics.ws_enabled ())
  then Some "WebSocket transport disabled"
  else if not (Transport_metrics.ws_same_origin_ready ())
  then Some "WebSocket transport not ready"
  else None

let websocket_auth_error message =
  Masc_domain.Auth
    (Masc_domain.Auth_error.Unauthorized
       { reason = Masc_domain.Auth_error.Generic; message })

let websocket_upgrade_authorized ~base_path request =
  match verify_mcp_auth ~base_path request with
  | Ok _ -> Ok ()
  | Error token_error ->
    (match ensure_same_origin_browser_request request with
     | Ok () -> Ok ()
     | Error origin_error ->
       let message =
         Printf.sprintf
           "%s Same-origin WebSocket upgrade rejected: %s"
           token_error
           (Masc_domain.masc_error_to_string origin_error)
       in
       Error (websocket_auth_error message))

let websocket_handler ?sw ?clock ~upgrade request reqd =
  if is_websocket_upgrade_request request then
    match websocket_upgrade_unavailable_reason () with
    | None ->
      let base_path =
        match current_server_state_opt () with
        | Some state -> (Mcp_server.workspace_config state).base_path
        | None -> Server_mcp_transport_http.default_base_path ()
      in
      (match websocket_upgrade_authorized ~base_path request with
       | Error err -> respond_auth_error request reqd err
       | Ok () ->
         (match
            Server_mcp_transport_ws.upgrade_connection
              ?sw
              ?clock
              ~on_message:Server_mcp_transport_ws.dispatch_inbound_message
              ~upgrade
              reqd
          with
          | Ok () -> ()
          | Error msg -> Http.Response.text ~status:`Bad_request msg reqd))
    | Some reason -> Http.Response.text ~status:`Service_unavailable reason reqd
  else
    websocket_discovery_handler request reqd

let webrtc_signaling_handler signaling_fn request reqd =
  with_permission_auth ~permission:Masc_domain.CanBroadcast
    (fun _state _req reqd ->
      if not (Server_webrtc_transport.is_enabled ()) then
        Http.Response.json_value ~status:`Not_found
          (`Assoc [ ("error", `String "webrtc transport disabled") ])
          reqd
      else
        Http.Request.read_body_async reqd (fun body_str ->
          match signaling_fn body_str with
          | Ok body ->
              Http.Response.json body reqd
          | Error msg ->
              Http.Response.json_value ~status:`Bad_request
                (`Assoc [ ("error", `String msg) ])
                reqd))
    request reqd

let add_routes ?sw ?clock ~port ~host router =
  router
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get Server_health_paths.liveness liveness_handler
  |> Http.Router.get Server_health_paths.readiness readiness_handler
  |> Http.Router.get "/.well-known/agent.json" (fun request reqd ->
         with_public_read (fun _state req reqd ->
         Http.Response.json_value (Runtime.agent_card_json req) reqd)
         request reqd)
  |> Http.Router.get "/.well-known/agent-card.json" (fun request reqd ->
         with_public_read (fun _state req reqd ->
         Http.Response.json_value (Runtime.agent_card_json req) reqd)
         request reqd)
  |> Http.Router.ws_get "/ws" (websocket_handler ?sw ?clock)
  (* RFC-0217 S4-2 — Otel_metric_store scrape endpoint removed; metrics now
     export via OTLP push (Otel_metrics observable). *)
  |> Http.Router.get "/ag-ui/events" handle_ag_ui_events
  |> Http.Router.get "/events/presence" handle_presence_events
  (* Dashboard Bonsai island — static JS bundle and SPA shell.
     Must precede /dashboard/assets/ and /dashboard/ catchalls below. *)
  |> Http.Router.prefix_get "/dashboard/b/assets/"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let req_path = Http.Request.path req in
           let prefix_len = String.length "/dashboard/b/assets/" in
           let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
           if Web_dashboard.is_safe_asset_relative_path filename then
             serve_bonsai_static filename req reqd
           else
             Http.Response.not_found reqd
         ) request reqd)
  (* Bonsai API — must precede the /dashboard/b/ SPA catchall. *)
  |> Http.Router.get "/dashboard/b/api/keepers/summary"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           bonsai_api_keepers_summary req reqd
         ) request reqd)
  |> Http.Router.get "/dashboard/b" (fun request reqd ->
       with_canonical_loopback_host ~port
         (fun request reqd ->
           with_public_read (fun _state req reqd ->
             serve_bonsai_index req reqd
           ) request reqd)
         request reqd)
  |> Http.Router.get "/dashboard/b/" (fun request reqd ->
       with_canonical_loopback_host ~port
         (fun request reqd ->
           with_public_read (fun _state req reqd ->
             serve_bonsai_index req reqd
           ) request reqd)
         request reqd)
  |> Http.Router.prefix_get "/dashboard/b/"
       (fun request reqd ->
         with_canonical_loopback_host ~port
           (fun request reqd ->
             with_public_read (fun _state req reqd ->
               serve_bonsai_index req reqd
             ) request reqd)
           request reqd)
  |> Http.Router.get "/favicon.ico" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  |> Http.Router.get "/favicon.svg" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_favicon req reqd
       ) request reqd)
  (* Dashboard SPA: static assets — prefix match for /dashboard/assets/* *)
  |> Http.Router.prefix_get "/dashboard/assets/"
       (fun request reqd ->
         let req_path = Http.Request.path request in
         let prefix_len = String.length "/dashboard/assets/" in
         let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
         if Web_dashboard.is_safe_asset_relative_path filename then
           serve_dashboard_static ("assets/" ^ filename) request reqd
         else
           Http.Response.not_found reqd)
  (* Dashboard SPA: index.html *)
  |> Http.Router.get "/dashboard" (fun request reqd ->
       with_canonical_loopback_host ~port
         (fun request reqd ->
           with_public_read (fun _state req reqd ->
             serve_dashboard_index req reqd
           ) request reqd)
         request reqd)
  |> Http.Router.get "/dashboard/" (fun request reqd ->
       with_canonical_loopback_host ~port
         (fun request reqd ->
           with_public_read (fun _state req reqd ->
             serve_dashboard_index req reqd
           ) request reqd)
         request reqd)
  |> Http.Router.prefix_get "/dashboard/"
       (fun request reqd ->
         with_canonical_loopback_host ~port
           (fun request reqd ->
             with_public_read (fun _state req reqd ->
               let req_path = Http.Request.path req in
               if is_dashboard_spa_deep_link req_path then
                 serve_dashboard_index req reqd
               else
                 Http.Response.not_found reqd
             ) request reqd)
           request reqd)
  |> Http.Router.get "/api/v1/openapi.json" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let host_header = Httpun.Headers.get req.Httpun.Request.headers "host" in
         let (resolved_host, resolved_port) = match host_header with
           | Some header -> parse_host_port (Some header) host port
           | None -> ("", 0)
         in
         let json =
           Transport.Rest.generate_openapi_document
             ~host:resolved_host ~port:resolved_port ()
         in
         Http.Response.json_value json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/voice/config" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let status, json = voice_config_payload () in
         let status =
           match status with `OK -> `OK | `Error -> `Internal_server_error
         in
         Http.Response.json_value ~status json reqd
       ) request reqd)
  |> Http.Router.get "/" (fun request reqd ->
       match canonical_root_dashboard_location ~default_port:port request with
       | Some location -> respond_redirect ~location reqd
       | None -> redirect_to_dashboard reqd)
  |> Http.Router.get "/static/css/middleware.css"
       (serve_playground_asset "static/css/middleware.css")
  |> Http.Router.get "/static/js/middleware.js"
       (serve_playground_asset "static/js/middleware.js")
  |> Http.Router.get "/graphiql/graphiql.min.css"
       (serve_graphiql_asset "graphiql.min.css")
  |> Http.Router.get "/graphiql/graphiql.min.js"
       (serve_graphiql_asset "graphiql.min.js")
  |> Http.Router.get "/graphiql/react.production.min.js"
       (serve_graphiql_asset "react.production.min.js")
  |> Http.Router.get "/graphiql/react-dom.production.min.js"
       (serve_graphiql_asset "react-dom.production.min.js")
  |> Http.Router.get "/mcp" (fun request reqd ->
       (* Observer/presence SSE streams authenticate via the `token` query
          param — an EventSource cannot set an Authorization header. Parse
          sse_kind and let handle_get_mcp route it: Observer/Presence go to
          verify_mcp_observer_stream_auth (accepts header OR `token` query),
          the default (Agent_stream) still requires a bearer header via
          verify_mcp_auth. Do NOT wrap in with_read_auth — that gate is
          header-only and 401s ("Token required") the query-token SSE
          handshake before the sse_kind-aware auth runs, which is why the
          dashboard observer stream failed and the client fell back/looped.
          Mirrors POST /mcp, which already self-auths via handle_post_mcp. *)
       let sse_kind =
         match Server_utils.query_param request "sse_kind" with
         | Some raw
           when String.equal "observer"
                  (String.lowercase_ascii (String.trim raw)) ->
             Some Sse.Observer
         | Some raw
           when String.equal "presence"
                  (String.lowercase_ascii (String.trim raw)) ->
             Some Sse.Presence
         | _ -> None
       in
       handle_get_mcp ?sse_kind request reqd)
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/managed"
       (handle_post_mcp ~profile:Server_mcp_transport_http.Managed_agent)
  |> Http.Router.add ~path:"/mcp" ~methods:[`DELETE]
       ~handler:handle_delete_mcp
  |> Http.Router.add ~path:"/mcp/managed" ~methods:[`DELETE]
       ~handler:(handle_delete_mcp ~profile:Server_mcp_transport_http.Managed_agent)
  |> Http.Router.post "/webrtc/offer"
       (webrtc_signaling_handler Server_webrtc_transport.handle_offer_request)
  |> Http.Router.post "/webrtc/answer"
       (webrtc_signaling_handler Server_webrtc_transport.handle_answer_request)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
