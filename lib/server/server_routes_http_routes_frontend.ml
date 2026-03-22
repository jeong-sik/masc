
open Server_auth
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime

module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime
module Keeper_stream = Server_routes_http_keeper_stream

let add_routes ~port ~host router =
  router
  |> Http.Router.get "/health" health_handler
  |> Http.Router.get "/metrics" (fun request reqd ->
       with_read_auth (fun _state _req reqd ->
         let body = Prometheus.to_prometheus_text () in
         Http.Response.bytes ~content_type:"text/plain; version=0.0.4; charset=utf-8" body reqd
       ) request reqd)
  |> Http.Router.get "/.well-known/agent.json" (serve_agent_card ~host ~port)
  |> Http.Router.get "/.well-known/agent-card.json" (serve_agent_card ~host ~port)
  |> Http.Router.get "/ag-ui/events" handle_ag_ui_events
  (* Dashboard sub-routes: must come before the SPA catchall *)
  |> Http.Router.get "/dashboard/credits" (fun request reqd ->
       with_public_read (fun _state _req reqd ->
         Http.Response.html (Credits_dashboard.html ()) reqd
       ) request reqd)
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
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.get "/dashboard/" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         serve_dashboard_index req reqd
       ) request reqd)
  |> Http.Router.prefix_get "/dashboard/"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let req_path = Http.Request.path req in
           if is_dashboard_spa_deep_link req_path then
             serve_dashboard_index req reqd
           else
             Http.Response.not_found reqd
         ) request reqd)
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
  |> Http.Router.get "/" (fun _req reqd -> Http.Response.text "MASC MCP Server" reqd)
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
  |> Http.Router.get "/mcp/operator" handle_get_operator_mcp
  |> Http.Router.post "/" handle_post_mcp
  |> Http.Router.post "/mcp" handle_post_mcp
  |> Http.Router.post "/mcp/managed" (handle_post_mcp ~profile:Mcp_eio.Managed_agent)
  |> Http.Router.post "/mcp/operator" (handle_post_mcp ~profile:Mcp_eio.Operator_remote)
  |> Http.Router.add ~path:"/graphql" ~methods:[`GET; `POST]
       ~handler:(fun request reqd ->
         with_read_auth (fun _state req reqd -> handle_graphql req reqd) request reqd)
  |> Http.Router.post "/messages" handle_post_messages
  |> Http.Router.get "/sse"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           handle_get_mcp ~sse_kind:Sse.Observer
             ~legacy_messages_endpoint:(legacy_messages_endpoint_url req)
             req reqd
         ) request reqd)
  |> Http.Router.get "/sse/simple" (fun request reqd ->
       with_public_read (fun _state req reqd -> sse_simple_handler req reqd) request reqd)
