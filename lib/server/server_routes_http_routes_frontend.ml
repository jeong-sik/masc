
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
  let body =
    websocket_discovery_json request |> Yojson.Safe.to_string
  in
  Http.Response.json body reqd

let webrtc_signaling_handler ~tool_name signaling_fn request reqd =
  with_tool_auth ~tool_name
    (fun _state _req reqd ->
      if not (Server_webrtc_transport.is_enabled ()) then
        Http.Response.json ~status:`Not_found
          {|{"error":"webrtc transport disabled"}|}
          reqd
      else
        Http.Request.read_body_async reqd (fun body_str ->
          match signaling_fn body_str with
          | Ok body ->
              Http.Response.json body reqd
          | Error msg ->
              Http.Response.json ~status:`Bad_request
                (Yojson.Safe.to_string
                   (`Assoc [ ("error", `String msg) ]))
                reqd))
    request reqd

let add_routes ~port ~host router =
  router
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get Server_health_paths.liveness liveness_handler
  |> Http.Router.get Server_health_paths.readiness readiness_handler
  |> Http.Router.get "/ws" websocket_discovery_handler
  |> Http.Router.get "/metrics" (fun request reqd ->
       with_read_auth (fun _state _req reqd ->
         let body = Prometheus.to_prometheus_text () in
         Http.Response.bytes ~content_type:"text/plain; version=0.0.4; charset=utf-8" body reqd
       ) request reqd)
  |> Http.Router.get "/ag-ui/events" handle_ag_ui_events
  |> Http.Router.get "/events/presence" handle_presence_events
  (* Dashboard sub-routes: must come before the SPA catchall *)
  |> Http.Router.get "/dashboard/credits" (fun request reqd ->
       with_canonical_loopback_host ~port
         (fun request reqd ->
           with_public_read (fun _state _req reqd ->
             Http.Response.html (Credits_dashboard.html ()) reqd
           ) request reqd)
         request reqd)
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
  |> Http.Router.get "/api/v1/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.json (Credits_dashboard.json_api ()) reqd
       ) request reqd)
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
           |> Yojson.Safe.to_string
         in
         Http.Response.json json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/voice/config" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         let status, json = voice_config_payload () in
         let status =
           match status with `OK -> `OK | `Error -> `Internal_server_error
         in
         Http.Response.json ~status (Yojson.Safe.to_string json) reqd
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
       with_read_auth (fun _state req reqd -> handle_get_mcp req reqd) request reqd)
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/managed"
       (handle_post_mcp ~profile:Server_mcp_transport_http.Managed_agent)
  |> Http.Router.post "/webrtc/offer"
       (webrtc_signaling_handler
          ~tool_name:"masc_webrtc_offer"
          Server_webrtc_transport.handle_offer_request)
  |> Http.Router.post "/webrtc/answer"
       (webrtc_signaling_handler
          ~tool_name:"masc_webrtc_answer"
          Server_webrtc_transport.handle_answer_request)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
  |> Http.Router.post "/messages" handle_post_messages
