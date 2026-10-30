
open Server_auth
open Server_routes_http_common
open Server_routes_http_pages
open Server_routes_http_runtime
open Server_voice_config

module Http = Http_server_eio
module Common = Server_routes_http_common
module Pages = Server_routes_http_pages
module Runtime = Server_routes_http_runtime

let respond_redirect = Server_canonical_host.respond_redirect
let authority_host_port = Server_canonical_host.authority_host_port
let canonical_loopback_location = Server_canonical_host.canonical_loopback_location

let canonical_root_dashboard_location ~default_port ~request_authority =
  let host, port = authority_host_port ~default_port request_authority in
  let canonical_host = Transport_read_model.normalize_advertised_host host in
  if String.equal canonical_host host then
    None
  else
    Some (Printf.sprintf "http://%s:%d/dashboard" canonical_host port)

let redirect_to_dashboard reqd =
  respond_redirect ~location:"/dashboard" reqd

let websocket_discovery_handler request reqd =
  let request_authority = Server_request_authority.current_exn () in
  Http.Response.json_value
    (websocket_discovery_json ~request_authority request)
    reqd

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

let websocket_upgrade_authorized ~base_path ~request_authority request =
  match verify_mcp_auth_for_authority ~base_path ~request_authority request with
  | Ok _ -> Ok ()
  | Error token_error ->
    (match ensure_same_origin_browser_request ~request_authority request with
     | Ok () -> Ok ()
     | Error origin_error ->
       let message =
         Printf.sprintf
           "%s Same-origin WebSocket upgrade rejected: %s"
           (Masc_domain.masc_error_to_string token_error)
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
      let request_authority = Server_request_authority.current_exn () in
      (match
         websocket_upgrade_authorized ~base_path ~request_authority request
       with
       | Error err ->
         (* Reject-boundary contract: every client-visible auth reject
            leaves a metric + log trace. The metric is recorded here; the
            log line comes from [respond_auth_error], which logs the refusal
            for both protocols, so this path leaves one line, not two. The
            response shape is unchanged. *)
         Server_mcp_transport_http_respond.record_mcp_auth_reject_metric
           ~endpoint:"GET /ws upgrade"
           (Server_mcp_transport_http_types.auth_failure_of_masc_error err);
         respond_auth_error request reqd err
       | Ok () ->
         (match
            Server_mcp_transport_ws.upgrade_connection
              ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
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

let add_routes ?sw ?clock ~port router =
  router
  |> Server_route.get Server_route.Always_public "/health" health_handler
  |> Server_route.get Server_route.Always_public Server_health_paths.liveness liveness_handler
  |> Server_route.get Server_route.Always_public Server_health_paths.readiness readiness_handler
  |> Server_route.get Server_route.Public_read "/.well-known/agent.json" (fun _state req reqd ->
         let request_authority = Server_request_authority.current_exn () in
         Http.Response.json_value
           (Runtime.agent_card_json ~request_authority req)
           reqd)
  |> Server_route.get Server_route.Public_read "/.well-known/agent-card.json" (fun _state req reqd ->
         let request_authority = Server_request_authority.current_exn () in
         Http.Response.json_value
           (Runtime.agent_card_json ~request_authority req)
           reqd)
  |> Server_route.ws_get "/ws" (websocket_handler ?sw ?clock)
  (* RFC-0217 S4-2 — Otel_metric_store scrape endpoint removed; metrics now
     export via OTLP push (Otel_metrics observable). *)
  |> Server_route.get (Server_route.Self_authenticated Route_access.Mcp_transport) "/ag-ui/events" handle_ag_ui_events
  |> Server_route.get (Server_route.Self_authenticated Route_access.Mcp_transport) "/events/presence" handle_presence_events
  |> Server_route.get Server_route.Public_read "/favicon.ico" (fun _state req reqd ->
         serve_favicon req reqd
       )
  |> Server_route.get Server_route.Public_read "/favicon.svg" (fun _state req reqd ->
         serve_favicon req reqd
       )
  (* Dashboard SPA: static assets — prefix match for /dashboard/assets/* *)
  |> Server_route.prefix_get Server_route.Always_public "/dashboard/assets/"
       (fun request reqd ->
         let req_path = Http.Request.path request in
         let prefix_len = String.length "/dashboard/assets/" in
         let filename = String.sub req_path prefix_len (String.length req_path - prefix_len) in
         if Web_dashboard.is_public_asset_relative_path filename then
           serve_dashboard_static ("assets/" ^ filename) request reqd
         else
           Http.Response.not_found reqd)
  (* Dashboard SPA: index.html. A request that names a loopback alias is
     redirected before the public read looks at the server's readiness or at the
     workspace precondition, which is the order these routes had before they
     carried a kind. *)
  |> Server_route.get
       (Server_route.Public_read_on_canonical_host { port })
       "/dashboard"
       (fun _state req reqd -> serve_dashboard_index req reqd)
  |> Server_route.get
       (Server_route.Public_read_on_canonical_host { port })
       "/dashboard/"
       (fun _state req reqd -> serve_dashboard_index req reqd)
  |> Server_route.prefix_get
       (Server_route.Public_read_on_canonical_host { port })
       "/dashboard/"
       (fun _state req reqd ->
         let req_path = Http.Request.path req in
         if is_dashboard_spa_deep_link req_path then
           serve_dashboard_index req reqd
         else
           Http.Response.not_found reqd)
  |> Server_route.get Server_route.Public_read "/api/v1/openapi.json" (fun _state req reqd ->
         let request_authority = Server_request_authority.current_exn () in
         let resolved_host, resolved_port =
           authority_host_port ~default_port:port request_authority
         in
         let json =
           Transport.Rest.generate_openapi_document
             ~host:resolved_host ~port:resolved_port ()
         in
         Http.Response.json_value json reqd
       )
  |> Server_route.get Server_route.Public_read "/api/v1/voice/config" (fun _state _req reqd ->
         let status, json = voice_config_payload () in
         let status =
           match status with `OK -> `OK | `Error -> `Internal_server_error
         in
         Http.Response.json_value ~status json reqd
       )
  |> Server_route.get Server_route.Always_public "/" (fun request reqd ->
       let request_authority = Server_request_authority.current_exn () in
       match
         canonical_root_dashboard_location ~default_port:port ~request_authority
       with
       | Some location -> respond_redirect ~location reqd
       | None -> redirect_to_dashboard reqd)
  |> Server_route.get Server_route.Always_public "/static/css/middleware.css"
       (serve_playground_asset "static/css/middleware.css")
  |> Server_route.get Server_route.Always_public "/static/js/middleware.js"
       (serve_playground_asset "static/js/middleware.js")
  |> Server_route.get Server_route.Always_public "/graphiql/graphiql.min.css"
       (serve_graphiql_asset "graphiql.min.css")
  |> Server_route.get Server_route.Always_public "/graphiql/graphiql.min.js"
       (serve_graphiql_asset "graphiql.min.js")
  |> Server_route.get Server_route.Always_public "/graphiql/react.production.min.js"
       (serve_graphiql_asset "react.production.min.js")
  |> Server_route.get Server_route.Always_public "/graphiql/react-dom.production.min.js"
       (serve_graphiql_asset "react-dom.production.min.js")
  |> Server_route.get (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp" (fun request reqd ->
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
  |> Server_route.get (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp/operator" handle_get_operator_mcp
  |> Server_route.post (Server_route.Self_authenticated Route_access.Mcp_transport) "/" handle_post_mcp
  |> Server_route.post (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp" handle_post_mcp
  |> Server_route.post (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp/managed"
       (handle_post_mcp ~profile:Server_mcp_transport_http.Managed_agent)
  |> Server_route.post (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp/operator"
       (handle_post_mcp ~profile:Server_mcp_transport_http.Operator_remote)
  (* No GET: the agent stream carries workspace task events a player must not
     see, so the router answers 405, which the MCP transport spec defines as
     "this endpoint offers no SSE stream". *)
  |> Server_route.post (Server_route.Self_authenticated Route_access.Mcp_transport) "/mcp/play"
       (handle_post_mcp ~profile:Server_mcp_transport_http.Seat)
  |> Server_route.add (Server_route.Self_authenticated Route_access.Mcp_transport) ~path:"/mcp" ~methods:[`DELETE]
       handle_delete_mcp
  |> Server_route.add (Server_route.Self_authenticated Route_access.Mcp_transport) ~path:"/mcp/managed" ~methods:[`DELETE]
       (handle_delete_mcp ~profile:Server_mcp_transport_http.Managed_agent)
  |> Server_route.add (Server_route.Self_authenticated Route_access.Mcp_transport) ~path:"/mcp/operator" ~methods:[`DELETE]
       (handle_delete_mcp ~profile:Server_mcp_transport_http.Operator_remote)
  |> Server_route.add (Server_route.Self_authenticated Route_access.Mcp_transport) ~path:"/mcp/play" ~methods:[`DELETE]
       (handle_delete_mcp ~profile:Server_mcp_transport_http.Seat)
  |> Server_route.add Server_route.Read_auth ~path:"/graphql" ~methods:[`GET; `POST]
       (fun _state req reqd -> handle_graphql req reqd)
