
open Types
open Server_auth
open Server_dashboard_http
open Server_routes_http

let make_error_handler () =
  (* HTTP/2 error handler *)
  let h2_error_handler _client_addr ?request:_ error respond =
    let message = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Internal_server_error -> "Internal server error"
    in
    Log.Http.error "Error: %s" message;
    let headers = H2.Headers.of_list [("content-type", "text/plain")] in
    let body = respond headers in
    H2.Body.Writer.write_string body message;
    H2.Body.Writer.close body
  in


  h2_error_handler

let make_request_handler ~sw ~clock ~server_start_time:_ =
  let mcp_eio_profile_of_transport_profile = function
    | Server_mcp_transport_http.Full -> Mcp_eio.Full
    | Server_mcp_transport_http.Managed_agent -> Mcp_eio.Managed_agent
    | Server_mcp_transport_http.Operator_remote -> Mcp_eio.Operator_remote
  in
  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Response Helpers - Reduce duplication in handlers
     ═══════════════════════════════════════════════════════════════════════ *)

  let h2_respond_json ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "application/json; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/plain; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
    let headers = H2.Headers.of_list ([
      ("content-type", "text/html; charset=utf-8");
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_removed_surface h2_reqd ~surface ~extra_headers =
    let body =
      Yojson.Safe.to_string
        (`Assoc
           [
             ("error", `String "removed_surface");
             ("surface", `String surface);
             ("message",
               `String
                 "This compatibility surface was removed. Keepers and local clients should use the OAS-backed repo coordination front door.");
           ])
    in
    h2_respond_json ~status:`Gone h2_reqd body ~extra_headers
  in

  let h2_respond_bytes
      ?(status = `OK)
      ?(extra_headers = [])
      ~content_type
      h2_reqd
      body =
    let headers = H2.Headers.of_list ([
      ("content-type", content_type);
      ("content-length", string_of_int (String.length body));
    ] @ extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.write_string writer body;
    H2.Body.Writer.close writer
  in

  let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
    let headers = H2.Headers.of_list (("content-length", "0") :: extra_headers) in
    let response = H2.Response.create ~headers status in
    let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
    H2.Body.Writer.close writer
  in

  (* Read H2 request body asynchronously *)
  let h2_read_body h2_reqd callback =
    let body = H2.Reqd.request_body h2_reqd in
    let buf = Buffer.create 4096 in
    let rec read_loop () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () -> callback (Buffer.contents buf))
        ~on_read:(fun bigstring ~off ~len ->
          let chunk = Bigstringaf.substring bigstring ~off ~len in
          Buffer.add_string buf chunk;
          read_loop ())
    in
    read_loop ()
  in

  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Request Handler - Full implementation
     ═══════════════════════════════════════════════════════════════════════ *)
  let h2_request_handler _client_addr h2_reqd =
    let h2_req = H2.Reqd.request h2_reqd in
    let h2_headers = h2_req.headers in
    (* Convert H2.Request to Httpun.Request for compatibility with existing code *)
    let httpun_headers = Httpun.Headers.of_list (H2.Headers.to_list h2_headers) in
    let httpun_meth = match h2_req.meth with
      | `GET -> `GET | `POST -> `POST | `DELETE -> `DELETE
      | `OPTIONS -> `OPTIONS | `PUT -> `PUT | `HEAD -> `HEAD
      | `CONNECT -> `CONNECT | `TRACE -> `TRACE | `Other s -> `Other s
    in
    let httpun_request = Httpun.Request.create ~headers:httpun_headers httpun_meth h2_req.target in
    let path = Http.Request.path httpun_request in
    let origin = match H2.Headers.get h2_headers "origin" with
      | Some o -> o | None -> "*"
    in
    let cors = cors_headers origin in
    (* [with_server_state] (#9793): HTTP-layer wrapper around
       [get_server_state_result]. Returns a controlled 500 JSON error when
       server state is not initialized, instead of crashing the request
       fiber. Mirrors the pattern [handle_post_graphql] already uses. *)
    let with_server_state h2_reqd f =
      match get_server_state_result () with
      | Ok state -> f state
      | Error message ->
          h2_respond_json h2_reqd
            (server_state_error_json message)
            ~status:`Internal_server_error ~extra_headers:cors
    in
    let session_id_opt = get_session_id_any httpun_request in
    let h2_respond_dashboard_index () =
      let index_path = dashboard_index_path () in
      match read_file index_path with
      | Ok body ->
          let etag_value = "\"" ^ dashboard_etag () ^ "\"" in
          let if_none_match = H2.Headers.get h2_headers "if-none-match" in
          (match if_none_match with
           | Some inm when String.equal inm etag_value ->
               let resp_headers = H2.Headers.of_list ([
                 ("etag", etag_value); ("cache-control", dashboard_index_cache_control);
               ] @ cors) in
               let response = H2.Response.create ~headers:resp_headers `Not_modified in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.close writer
           | _ ->
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control); ("vary", "Accept-Encoding")] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)
      | Error _ ->
          h2_respond_html h2_reqd "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; pnpm run build</body></html>" ~extra_headers:cors
    in

    let _h2_authorize_tool state ~tool_name =
      authorize_tool_request
        ~base_path:state.Mcp_server.room_config.base_path
        ~tool_name httpun_request
    in

    let dispatch_h2_route () =
      match httpun_meth, path with
      (* ─────────────────────────────────────────────────────────────────────
         Health & Metrics
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/health" ->
          let body =
            Server_routes_http_runtime.make_health_json ~listener:"h2" httpun_request
            |> Yojson.Safe.to_string
          in
          h2_respond_json h2_reqd body ~extra_headers:cors

      | `GET, p when String.equal p Server_health_paths.liveness ->
          let body =
            Yojson.Safe.to_string
              (`Assoc [
                 ("live", `Bool true);
                 ("startup", Server_startup_state.to_yojson ());
               ])
          in
          h2_respond_json h2_reqd body ~extra_headers:cors

      | `GET, p when String.equal p Server_health_paths.readiness ->
          let current = Server_startup_state.(!state) in
          let body, status =
            if current.state_ready then
              (Yojson.Safe.to_string
                 (`Assoc [
                    ("ready", `Bool true);
                    ("phase", `String (Server_startup_state.phase_to_string current.phase));
                    ("backend_mode", `String current.backend_mode);
                  ]),
               `OK)
            else
              (Yojson.Safe.to_string
                 (`Assoc [
                    ("ready", `Bool false);
                    ("phase", `String (Server_startup_state.phase_to_string current.phase));
                    ("elapsed_sec", `Float (Server_startup_state.elapsed_since_start ()));
                  ]),
               `Service_unavailable)
          in
          h2_respond_json ~status h2_reqd body ~extra_headers:cors

      | `GET, "/ws" ->
          let body =
            Server_routes_http_runtime.websocket_discovery_json httpun_request
            |> Yojson.Safe.to_string
          in
          h2_respond_json h2_reqd body ~extra_headers:cors

      | `POST, "/webrtc/offer" ->
          if not (Server_webrtc_transport.is_enabled ()) then
            h2_respond_json h2_reqd {|{"error":"webrtc transport disabled"}|}
              ~status:`Not_found ~extra_headers:cors
          else
            with_server_state h2_reqd (fun state ->
              match
                authorize_tool_request
                  ~base_path:state.Mcp_server.room_config.base_path
                  ~tool_name:"masc_webrtc_offer"
                  httpun_request
              with
              | Error err ->
                  let status = http_status_of_auth_error err in
                  h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
              | Ok () ->
                  h2_read_body h2_reqd (fun body_str ->
                    match Server_webrtc_transport.handle_offer_request body_str with
                    | Ok body ->
                        h2_respond_json h2_reqd body ~extra_headers:cors
                    | Error msg ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ]))
                          ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/webrtc/answer" ->
          if not (Server_webrtc_transport.is_enabled ()) then
            h2_respond_json h2_reqd {|{"error":"webrtc transport disabled"}|}
              ~status:`Not_found ~extra_headers:cors
          else
            with_server_state h2_reqd (fun state ->
              match
                authorize_tool_request
                  ~base_path:state.Mcp_server.room_config.base_path
                  ~tool_name:"masc_webrtc_answer"
                  httpun_request
              with
              | Error err ->
                  let status = http_status_of_auth_error err in
                  h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
              | Ok () ->
                  h2_read_body h2_reqd (fun body_str ->
                    match Server_webrtc_transport.handle_answer_request body_str with
                    | Ok body ->
                        h2_respond_json h2_reqd body ~extra_headers:cors
                    | Error msg ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (`Assoc [ ("error", `String msg) ]))
                          ~status:`Bad_request ~extra_headers:cors))

      | `GET, "/metrics" ->
          let body = Prometheus.to_prometheus_text () in
          let headers = H2.Headers.of_list ([
            ("content-type", "text/plain; version=0.0.4; charset=utf-8");
            ("content-length", string_of_int (String.length body));
          ] @ cors) in
          let response = H2.Response.create ~headers `OK in
          let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
          H2.Body.Writer.write_string writer body;
          H2.Body.Writer.close writer

      | `GET, "/" ->
          h2_respond_text h2_reqd "MASC MCP Server (HTTP/2)" ~extra_headers:cors

      | `GET, "/favicon.ico" | `GET, "/favicon.svg" ->
          h2_respond_bytes
            h2_reqd
            favicon_svg
            ~content_type:"image/svg+xml"
            ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         CORS Preflight
         ───────────────────────────────────────────────────────────────────── *)
      | `OPTIONS, _ ->
          h2_respond_empty h2_reqd ~extra_headers:(cors_preflight_headers origin)

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `POST, "/mcp" | `POST, "/" | `POST, "/mcp/managed" ->
          let session_was_provided = Option.is_some session_id_opt in
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let auth_token = auth_token_from_request httpun_request in
          let protocol_version = get_protocol_version_for_session ~session_id httpun_request in
          let profile =
            if String.equal path "/mcp/managed"
            then Server_mcp_transport_http.Managed_agent
            else Server_mcp_transport_http.Full
          in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Server_mcp_transport_http.Full
            | Server_mcp_transport_http.Managed_agent ->
                verify_mcp_auth ~base_path httpun_request
            | Server_mcp_transport_http.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match validate_mcp_session_profile ~profile session_id with
           | Error msg ->
               let body = json_rpc_error (-32600) msg in
               h2_respond_json h2_reqd body ~status:`Conflict ~extra_headers:cors
           | Ok () ->
               (match Server_mcp_transport_http.validate_protocol_version_continuity
                        ~session_id httpun_request with
                | Error msg ->
                    let body = json_rpc_error (-32600) msg in
                    h2_respond_json h2_reqd body ~status:`Bad_request
                      ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                | Ok () ->
                    remember_mcp_profile session_id profile;
                    (match auth_result with
                     | Error msg ->
                         let body = json_rpc_error (-32001) msg in
                         h2_respond_json h2_reqd body ~status:`Unauthorized ~extra_headers:(("www-authenticate", "Bearer") :: cors)
                     | Ok _cred_opt ->
                         h2_read_body h2_reqd (fun body_str ->
                             match
                               Server_mcp_transport_http
                               .validate_session_requirement
                                 ~session_was_provided body_str
                             with
                             | Error msg ->
                                 let body = json_rpc_error (-32600) msg in
                                 h2_respond_json h2_reqd body
                                   ~status:`Bad_request
                                   ~extra_headers:
                                     (cors
                                     @ mcp_headers session_id
                                         protocol_version)
                             | Ok () ->
                             let accept_mode =
                               Server_mcp_transport_http_headers
                               .classify_mcp_accept_for_body httpun_request body_str
                             in
                             match accept_mode with
                             | Http_negotiation.Rejected ->
                                 let body =
                                   json_rpc_error (-32600)
                                     "Invalid Accept header: must include application/json and text/event-stream. \
                                      Set MASC_ALLOW_LEGACY_ACCEPT=1 for temporary compatibility."
                                 in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                             | accept_mode ->
                                 let accept_warn_headers =
                                   legacy_accept_warning_headers accept_mode
                                 in
                                 with_server_state h2_reqd (fun state ->
                                   let profile =
                                     mcp_eio_profile_of_transport_profile profile
                                   in
                                   let response_json =
                                     Mcp_eio.handle_request ~clock ~sw ~profile
                                       ~mcp_session_id:session_id ?auth_token state body_str
                                   in
                                   (match protocol_version_from_body body_str with
                                   | Some v -> remember_protocol_version session_id v
                                   | None -> ());
                                   let protocol_version =
                                     get_protocol_version_for_session ~session_id
                                       httpun_request
                                   in
                                   let mcp_hdrs =
                                     accept_warn_headers @ mcp_headers session_id protocol_version
                                     @ cors
                                   in
                                   match response_json with
                                   | `Null ->
                                       h2_respond_empty h2_reqd ~status:`Accepted
                                         ~extra_headers:mcp_hdrs
                                   | json when is_http_error_response json ->
                                       let body = Yojson.Safe.to_string json in
                                       h2_respond_json h2_reqd body ~status:`Bad_request
                                         ~extra_headers:mcp_hdrs
                                   | json ->
                                       let body = Yojson.Safe.to_string json in
                                       h2_respond_json h2_reqd body ~extra_headers:mcp_hdrs)))))

      | `DELETE, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `DELETE, "/mcp" | `DELETE, "/mcp/managed" ->
          let profile =
            if String.equal path "/mcp/managed"
            then Server_mcp_transport_http.Managed_agent
            else Server_mcp_transport_http.Full
          in
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Server_mcp_transport_http.Full
            | Server_mcp_transport_http.Managed_agent ->
                verify_mcp_auth ~base_path httpun_request
            | Server_mcp_transport_http.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match auth_result with
           | Error msg ->
               let body = json_rpc_error (-32001) msg in
               h2_respond_json h2_reqd body ~status:`Unauthorized
                 ~extra_headers:(("www-authenticate", "Bearer") :: cors)
           | Ok _ ->
               (match session_id_opt with
                | Some session_id -> (
                    match validate_mcp_session_delete_profile ~profile session_id with
                    | Error msg ->
                        let body = json_rpc_error (-32600) msg in
                        h2_respond_json h2_reqd body ~status:`Conflict
                          ~extra_headers:cors
                    | Ok () ->
                        (match Server_mcp_transport_http.validate_protocol_version_continuity
                                 ~session_id httpun_request with
                         | Error msg ->
                             let body = json_rpc_error (-32600) msg in
                             h2_respond_json h2_reqd body ~status:`Bad_request
                               ~extra_headers:(cors @ mcp_headers session_id (get_protocol_version httpun_request))
                         | Ok () ->
                             stop_sse_session session_id;
                             Sse.unregister session_id;
                             forget_mcp_session session_id;
                             Log.info ~ctx:"h2_gateway" "Session terminated: %s" session_id;
                             let mcp_hdrs = mcp_headers session_id (get_protocol_version httpun_request) in
                             h2_respond_empty h2_reqd ~extra_headers:mcp_hdrs))
                | None ->
                    h2_respond_text h2_reqd "Mcp-Session-Id required" ~status:`Bad_request ~extra_headers:cors))

      (* ─────────────────────────────────────────────────────────────────────
         Dashboard
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/dashboard" | `GET, "/dashboard/" ->
          h2_respond_dashboard_index ()

      | `GET, "/dashboard/credits" ->
          h2_respond_html h2_reqd (Credits_dashboard.html ()) ~extra_headers:cors

      | `GET, p when is_dashboard_spa_deep_link p ->
          h2_respond_dashboard_index ()

      (* ─────────────────────────────────────────────────────────────────────
         GraphQL
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/graphql" ->
          let nonce =
            let rng = Random.State.make_self_init () in
            let bytes = Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256)) in
            Base64.encode_string (Bytes.to_string bytes)
          in
          let csp_header = ("content-security-policy", graphql_csp_header nonce) in
          h2_respond_html h2_reqd (graphql_playground_html ~nonce) ~extra_headers:(csp_header :: cors)

      | `POST, "/graphql" ->
          h2_read_body h2_reqd (fun body_str ->
            with_server_state h2_reqd (fun state ->
              let response = Graphql_api.handle_request ~config:state.room_config body_str in
              let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
              h2_respond_json h2_reqd response.body ~status ~extra_headers:cors))

      (* ─────────────────────────────────────────────────────────────────────
         REST API
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/api/v1/dashboard" ->
          let json =
            `Assoc
              [
                ("error", `String "dashboard batch contract removed");
                ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
              ]
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json)
            ~status:`Gone ~extra_headers:cors

      | `GET, "/api/v1/dashboard/shell" ->
          with_server_state h2_reqd (fun state ->
            let light =
              Server_utils.bool_query_param httpun_request "light" ~default:false
            in
            let json =
              dashboard_shell_http_json ?clock:state.Mcp_server.clock
                ~request:httpun_request ~light
                state.Mcp_server.room_config
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/config" ->
          let json = Env_config_introspect.to_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/config/excuse-patterns" ->
          let patterns = Anti_rationalization.load_excuse_patterns () in
          let json_items = List.map (fun (pat, reason) -> `List [`String pat; `String reason]) patterns in
          let json = `List json_items in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `POST, "/api/v1/dashboard/config/excuse-patterns" ->
          h2_read_body h2_reqd (fun body_str ->
            try
               let json = Yojson.Safe.from_string body_str in
               match Anti_rationalization.parse_excuse_patterns_json json with
               | Error msg ->
                   let err_json = Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)]) in
                   h2_respond_json h2_reqd err_json ~status:`Bad_request ~extra_headers:cors
               | Ok patterns ->
                   (match Anti_rationalization.save_excuse_patterns patterns with
                   | Ok () ->
                       h2_respond_json h2_reqd {|{"ok":true}|} ~extra_headers:cors
                   | Error msg ->
                       let err_json = Yojson.Safe.to_string (`Assoc [("ok", `Bool false); ("error", `String msg)]) in
                       h2_respond_json h2_reqd err_json ~status:`Internal_server_error ~extra_headers:cors)
             with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | _exn ->
               h2_respond_json h2_reqd
                 {|{"ok":false,"error":"Invalid JSON body"}|}
                 ~status:`Bad_request ~extra_headers:cors
          )

      | `GET, "/api/v1/dashboard/project-snapshot"
      | `GET, "/api/v1/dashboard/namespace-truth"
      | `GET, "/api/v1/dashboard/room-truth" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_namespace_truth_http_json ~state ~sw ~clock httpun_request
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/execution" ->
          with_server_state h2_reqd (fun state ->
            let json = dashboard_execution_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/execution-trust" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_execution_trust_http_json ~state ~sw ~clock
                httpun_request
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/board" ->
          let json = dashboard_memory_http_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/governance" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_governance_http_json httpun_request
                ~base_path:state.Mcp_server.room_config.base_path
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/planning" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_planning_http_json
                ~config:state.Mcp_server.room_config
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/goals" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_goals_tree_http_json
                ~config:state.Mcp_server.room_config
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/goals/detail" ->
          with_server_state h2_reqd (fun state ->
            let goal_id =
              match Server_utils.query_param httpun_request "goal_id" with
              | Some value -> String.trim value
              | None -> ""
            in
            if goal_id = "" then
              h2_respond_json h2_reqd
                {|{"ok":false,"error":"goal_id query param is required"}|}
                ~status:`Bad_request ~extra_headers:cors
            else
              let json =
                dashboard_goal_detail_http_json
                  ~config:state.Mcp_server.room_config ~goal_id
              in
              h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/tasks/history" ->
          with_server_state h2_reqd (fun state ->
            let task_id =
              match Server_utils.query_param httpun_request "task_id" with
              | Some value -> String.trim value
              | None -> ""
            in
            if task_id = "" then
              h2_respond_json h2_reqd {|{"error":"task_id is required"}|}
                ~status:`Bad_request ~extra_headers:cors
            else
              let limit =
                Server_utils.int_query_param httpun_request "limit" ~default:50
                |> Server_utils.clamp ~min_v:1 ~max_v:200
              in
              let json =
                Tool_task.task_history_events_json state.Mcp_server.room_config
                  ~task_id ~limit
              in
              h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/mission" ->
          with_server_state h2_reqd (fun state ->
            let json = dashboard_mission_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/session" ->
          with_server_state h2_reqd (fun state ->
            let json = dashboard_session_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/mission/briefing" ->
          with_server_state h2_reqd (fun state ->
            let json =
              dashboard_mission_briefing_http_json ~state ~sw ~clock
                httpun_request
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/transport-health" ->
          with_server_state h2_reqd (fun state ->
            let json = dashboard_transport_health_http_json ~state in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/perf" ->
          with_server_state h2_reqd (fun state ->
            let json = dashboard_perf_http_json state.Mcp_server.room_config in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/autoresearch/loops" ->
          with_server_state h2_reqd (fun state ->
            let base_path = state.Mcp_server.room_config.base_path in
            let json =
              Dashboard_http_autoresearch.autoresearch_loops_json ~base_path ()
            in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/autoresearch/loops/csv" ->
          with_server_state h2_reqd (fun state ->
            let base_path = state.Mcp_server.room_config.base_path in
            let csv = Dashboard_http_autoresearch.autoresearch_loops_csv ~base_path in
            let headers =
              H2.Headers.of_list
                [
                  ("content-type", "text/csv; charset=utf-8");
                  ("content-disposition", "attachment; filename=\"autoresearch_loops.csv\"");
                ]
            in
            let response = H2.Response.create ~headers `OK in
            let body = H2.Reqd.respond_with_streaming h2_reqd response in
            H2.Body.Writer.write_string body csv;
            H2.Body.Writer.close body)

      | `GET, p
        when String.starts_with ~prefix:"/api/v1/autoresearch/loops/" p
             && String.length p > 27 ->
          with_server_state h2_reqd (fun state ->
            let base_path = state.Mcp_server.room_config.base_path in
            let loop_id = String.trim (String.sub p 27 (String.length p - 27)) in
            if String.length loop_id = 0 then
              h2_respond_json h2_reqd {|{"error":"loop_id is required"}|}
                ~status:`Bad_request ~extra_headers:cors
            else
              (match
                 Dashboard_http_autoresearch.autoresearch_loop_detail_json
                   ~base_path ~loop_id ~history_limit:100
               with
               | Ok json ->
                   h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
               | Error msg ->
                   h2_respond_json h2_reqd
                     (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                     ~status:`Not_found ~extra_headers:cors
               | exception Invalid_argument msg ->
                   h2_respond_json h2_reqd
                     (Printf.sprintf {|{"error":"%s"}|} (String.escaped msg))
                     ~status:`Not_found ~extra_headers:cors))

      | `GET, p when String.starts_with ~prefix:"/api/v1/command-plane" p ->
          h2_respond_removed_surface h2_reqd ~surface:"command_plane" ~extra_headers:cors

      | `GET, "/api/v1/status" ->
          with_server_state h2_reqd (fun state ->
            let config = state.Mcp_server.room_config in
            let room_state = Coord.read_state config in
            let tempo = Tempo.get_tempo config in
            let json = `Assoc [
              ("cluster", `String (Env_config_core.cluster_name ()));
              ("project", `String room_state.project);
              ("tempo_interval_s", `Float tempo.current_interval_s);
              ("paused", `Bool room_state.paused);
            ] in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)

      | `GET, "/api/v1/credits" ->
          h2_respond_json h2_reqd (Credits_dashboard.json_api ()) ~extra_headers:cors

      | `GET, "/api/v1/openapi.json" ->
          let host_header = get_header_any_case httpun_request.headers "host" in
          let (resolved_host, resolved_port) = match host_header with
            | Some header -> parse_host_port (Some header)
                (Env_config_core.masc_host ()) (Env_config_core.masc_http_port_int ())
            | None -> ("", 0)
          in
          let json =
            Transport.Rest.generate_openapi_document
              ~host:resolved_host ~port:resolved_port ()
            |> Yojson.Safe.to_string
          in
          h2_respond_json h2_reqd json ~extra_headers:cors

      | `GET, "/api/v1/namespace/current"
      | `GET, "/api/v1/room/current"
      | `POST, "/api/v1/namespace/current"
      | `POST, "/api/v1/room/current" ->
          h2_respond_removed_surface h2_reqd ~surface:"namespace" ~extra_headers:cors

      | `POST, p when String.starts_with ~prefix:"/api/v1/command-plane" p ->
          h2_respond_removed_surface h2_reqd ~surface:"command_plane" ~extra_headers:cors

      (* ═══════════════════════════════════════════════════════════════════════
         Delegated route groups
         ═══════════════════════════════════════════════════════════════════════ *)
      | _ when Server_h2_gateway_routes_extra.dispatch ~h2_reqd ~httpun_request ~cors ~path httpun_meth -> ()

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    try
      dispatch_h2_route ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      let msg = Printexc.to_string exn in
      Log.Http.error "Handler error: %s" msg;
      h2_respond_text h2_reqd ("500 Internal Server Error: " ^ msg) ~status:`Internal_server_error ~extra_headers:cors
  in
  (* H2 error handler *)
  let _h2_error_handler _client_addr ?request:_ error respond =
    let msg = match error with
      | `Exn exn -> Printexc.to_string exn
      | `Bad_request -> "Bad request"
      | `Bad_gateway -> "Bad gateway"
      | `Internal_server_error -> "Internal server error"
    in
    let headers = H2.Headers.of_list [
      ("content-type", "text/plain");
      ("content-length", string_of_int (String.length msg));
    ] in
    let body = respond headers in
    H2.Body.Writer.write_string body msg;
    H2.Body.Writer.close body
  in


  h2_request_handler
