
open Masc_domain
open Server_auth
open Server_dashboard_http
open Server_h2_gateway_helpers
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
     Route-local query helpers
     ═══════════════════════════════════════════════════════════════════════ *)

  let trimmed_query_param req key =
    match Server_utils.query_param req key |> Option.map String.trim with
    | Some value when value <> "" -> Some value
    | _ -> None
  in

  let oas_telemetry_limit_param req =
    Server_utils.int_query_param req "limit" ~default:50
    |> Server_utils.clamp ~min_v:1 ~max_v:200
  in

  let oas_telemetry_provider_param req =
    trimmed_query_param req "provider"
  in

  (* ═══════════════════════════════════════════════════════════════════════
     HTTP/2 Request Handler - Full implementation
     ═══════════════════════════════════════════════════════════════════════ *)
  let h2_request_handler _client_addr h2_reqd =
    let h2_req = H2.Reqd.request h2_reqd in
    let h2_headers = h2_req.headers in
    (* Convert H2.Request to Httpun.Request for compatibility with existing code *)
    let httpun_headers = httpun_headers_of_h2 h2_headers in
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
    (* Reuse the H1 CORS admission SSOT. Invalid cross-origin requests never
       receive a reflected Access-Control-Allow-Origin value. *)
    let cors = public_read_cors_headers httpun_request in
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
    let with_mcp_http_transport h2_reqd state f =
      match state.Mcp_server.mcp_http_transport with
      | Some transport -> f transport
      | None ->
          h2_respond_json h2_reqd
            (json_rpc_error Mcp_error_code.Internal_error
               "MCP HTTP transport session store is unavailable")
            ~status:`Service_unavailable ~extra_headers:cors
    in
    let h2_respond_auth_error h2_reqd err =
      let status = http_status_of_auth_error err in
      h2_respond_json
        h2_reqd
        (auth_error_json err)
        ~status:(status :> H2.Status.t)
        ~extra_headers:cors
    in
    let h2_respond_mcp_lifecycle_error h2_reqd ~extra_headers = function
      | Server_mcp_transport_http.Session_owner_rejected { message } ->
          h2_respond_json h2_reqd
            (json_rpc_error Mcp_error_code.Auth_error message)
            ~status:`Forbidden ~extra_headers
      | ( Server_mcp_transport_http.Session_terminating _
        | Server_mcp_transport_http.Session_unknown _ ) as lifecycle_error ->
          let message =
            Server_mcp_transport_http.mcp_session_lifecycle_error_to_string
              lifecycle_error
          in
          h2_respond_json h2_reqd
            (json_rpc_error Mcp_error_code.Invalid_request message)
            ~status:`Not_found ~extra_headers
    in
    let h2_respond_agent_rate_limited h2_reqd ~rl_key =
      h2_respond_json h2_reqd
        (Rate_limit.too_many_agent_requests_body ())
        ~status:`Too_many_requests
        ~extra_headers:(Rate_limit.headers_agent_global ~key:rl_key @ cors)
    in
    let h2_check_agent_rate_limit h2_reqd =
      match agent_rl_key_of_request httpun_request with
      | None -> Ok ()
      | Some rl_key ->
          if Rate_limit.check_agent_global ~key:rl_key then Ok ()
          else (
            h2_respond_agent_rate_limited h2_reqd ~rl_key;
            Error ())
    in
    let with_h2_read_auth h2_reqd f =
      with_server_state h2_reqd (fun state ->
        match
          authorize_read_request
            ~base_path:(Mcp_server.workspace_config state).base_path
            httpun_request
        with
        | Ok () ->
            (match h2_check_agent_rate_limit h2_reqd with
             | Ok () -> f state
             | Error () -> ())
        | Error err -> h2_respond_auth_error h2_reqd err)
    in
    let with_h2_public_read h2_reqd f =
      let with_initialized_state f =
        match get_server_state_result () with
        | Ok state -> f state
        | Error _message ->
            h2_respond_json h2_reqd
              (not_initialized_response path)
              ~extra_headers:cors
      in
      if http_auth_strict_enabled () && not (is_public_read_path path)
      then
        with_initialized_state (fun state ->
          match
            authorize_read_request
              ~base_path:(Mcp_server.workspace_config state).base_path
              httpun_request
          with
          | Ok () ->
              (match h2_check_agent_rate_limit h2_reqd with
               | Ok () -> f state
               | Error () -> ())
          | Error err -> h2_respond_auth_error h2_reqd err)
      else with_initialized_state f
    in
    let with_h2_token_permission_auth h2_reqd ~permission f =
      with_server_state h2_reqd (fun state ->
        match
          authorize_token_bound_permission_request
            ~base_path:(Mcp_server.workspace_config state).base_path
            ~permission
            httpun_request
        with
        | Ok agent_name ->
            (match h2_check_agent_rate_limit h2_reqd with
             | Ok () -> f state agent_name
             | Error () -> ())
        | Error err -> h2_respond_auth_error h2_reqd err)
    in
    let with_h2_transport_admission h2_reqd ~permission f =
      with_server_state h2_reqd (fun state ->
        match
          authorize_token_bound_admission_request
            ~base_path:(Mcp_server.workspace_config state).base_path
            ~permission
            httpun_request
        with
        | Ok admission ->
            (match h2_check_agent_rate_limit h2_reqd with
             | Ok () -> f state admission
             | Error () -> ())
        | Error err -> h2_respond_auth_error h2_reqd err)
    in
    let session_id_opt = get_session_id_any httpun_request in
    let h2_respond_dashboard_index () =
      let index_path = dashboard_index_path () in
      match read_file index_path with
      | Ok body ->
          let etag_value = "\"" ^ dashboard_etag_of_body body ^ "\"" in
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

    let dispatch_h2_route () =
      match httpun_meth, path with
      (* ─────────────────────────────────────────────────────────────────────
         Health & Metrics
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/health" ->
          let json =
            Server_routes_http_runtime.make_health_response_json ~listener:"h2" httpun_request
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors

      | `GET, p when String.equal p Server_health_paths.liveness ->
          let json =
            `Assoc [
              ("live", `Bool true);
              ("startup", Server_startup_state.to_yojson ());
            ]
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors

      | `GET, p when String.equal p Server_health_paths.readiness ->
          let current = Server_startup_state.(!state) in
          let json, status =
            if current.state_ready then
              (`Assoc [
                 ("ready", `Bool true);
                 ("phase", `String (Server_startup_state.phase_to_string current.phase));
                 ("backend_mode", `String current.backend_mode);
               ],
               `OK)
            else
              (`Assoc [
                 ("ready", `Bool false);
                 ("phase", `String (Server_startup_state.phase_to_string current.phase));
                 ("elapsed_sec", `Float (Server_startup_state.elapsed_since_start ()));
               ],
               `Service_unavailable)
          in
          h2_respond_json_value ~status h2_reqd json ~extra_headers:cors

      | `GET, ("/.well-known/agent.json" | "/.well-known/agent-card.json") ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd
              (Server_routes_http_runtime.agent_card_json httpun_request)
              ~extra_headers:cors)

      | `GET, "/ws" ->
          let json =
            Server_routes_http_runtime.websocket_discovery_json httpun_request
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors

      | `POST, "/webrtc/offer" ->
          if not (Server_webrtc_transport.is_enabled ()) then
            h2_respond_json_value h2_reqd
              (`Assoc [ ("error", `String "webrtc transport disabled") ])
              ~status:`Not_found ~extra_headers:cors
          else
            with_h2_transport_admission
              h2_reqd
              ~permission:Masc_domain.CanBroadcast
              (fun _state admission ->
                  h2_read_body h2_reqd (fun body_str ->
                    match
                      Server_webrtc_transport.handle_offer_request ~admission body_str
                    with
                    | Ok body ->
                        h2_respond_json h2_reqd body ~extra_headers:cors
                    | Error msg ->
                        h2_respond_json_value h2_reqd
                          (`Assoc [ ("error", `String msg) ])
                          ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/webrtc/answer" ->
          if not (Server_webrtc_transport.is_enabled ()) then
            h2_respond_json_value h2_reqd
              (`Assoc [ ("error", `String "webrtc transport disabled") ])
              ~status:`Not_found ~extra_headers:cors
          else
            with_h2_transport_admission
              h2_reqd
              ~permission:Masc_domain.CanBroadcast
              (fun _state admission ->
                  h2_read_body h2_reqd (fun body_str ->
                    match
                      Server_webrtc_transport.handle_answer_request ~admission body_str
                    with
                    | Ok body ->
                        h2_respond_json h2_reqd body ~extra_headers:cors
                    | Error msg ->
                        h2_respond_json_value h2_reqd
                          (`Assoc [ ("error", `String msg) ])
                          ~status:`Bad_request ~extra_headers:cors))

      (* RFC-0217 S4-2 — Otel_metric_store scrape endpoint removed; metrics
         now export via OTLP push (Otel_metrics observable). *)
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
          h2_respond_empty h2_reqd ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `POST, "/mcp" | `POST, "/mcp/managed" ->
          with_server_state h2_reqd (fun state ->
          with_mcp_http_transport h2_reqd state (fun transport ->
          let sessions =
            Server_mcp_transport_http.mcp_transport_sessions transport
          in
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let profile =
            if String.equal path "/mcp/managed"
            then Server_mcp_transport_http.Managed_agent
            else Server_mcp_transport_http.Full
          in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = (Mcp_server.workspace_config state).base_path in
          let context =
            Server_mcp_request_context.make ~session_id_opt
              ~generated_session_id:session_id
              ~auth_token:(auth_token_from_request httpun_request)
              ~protocol_version:
                (get_protocol_version_for_session ~sessions ~session_id
                   httpun_request)
              ~origin ~base_path
          in
          let session_id = context.session_id in
          let auth_token = context.auth_token in
          let protocol_version = context.protocol_version in
          let initial_session_visibility =
            Server_mcp_transport_http_headers.session_header_visibility
              ~session_was_provided:context.session_was_provided
              ~initialized:false
          in
          let initial_mcp_headers =
            cors
            @ Server_mcp_transport_http_headers.mcp_response_headers
                ~visibility:initial_session_visibility ~session_id
                ~protocol_version
          in
          let auth_result =
            Server_mcp_transport_http.authorize_mcp_profile_admission
              ~base_path ~profile httpun_request
          in
          (match auth_result with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err)
                 ~status:(status :> H2.Status.t)
                 ~extra_headers:initial_mcp_headers
           | Ok admission ->
               (match
                  Server_mcp_transport_http.validate_mcp_session_owner_for_request
                    ~sessions ~session_id ~requester:admission.identity
                with
                | Error msg ->
                    let body = json_rpc_error Mcp_error_code.Auth_error msg in
                    h2_respond_json h2_reqd body ~status:`Forbidden
                      ~extra_headers:initial_mcp_headers
                | Ok () ->
                    (match
                       validate_mcp_session_profile ~sessions ~profile session_id
                     with
                     | Error msg ->
                         let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                         h2_respond_json h2_reqd body ~status:`Conflict
                           ~extra_headers:initial_mcp_headers
                     | Ok () ->
                         (match
                            Server_mcp_transport_http.validate_protocol_version_continuity
                              ~sessions ~session_id httpun_request
                          with
                          | Error msg ->
                              let body =
                                json_rpc_error Mcp_error_code.Invalid_request msg
                              in
                              h2_respond_json h2_reqd body ~status:`Bad_request
                                ~extra_headers:initial_mcp_headers
                          | Ok () ->
                         h2_read_body h2_reqd (fun body_str ->
                             match
                               Server_mcp_request_context.decide_post_body
                                 ~request:httpun_request ~context
                                 ~session_is_known:
                                   (Server_mcp_transport_http.is_known_session
                                      ~sessions session_id)
                                 body_str
                             with
                             | Error
                                 (Server_mcp_request_context.Session_required msg)
                               ->
                                 let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                 h2_respond_json h2_reqd body
                                   ~status:`Bad_request
                                   ~extra_headers:initial_mcp_headers
                             | Error
                                 (Server_mcp_request_context.Unknown_session msg)
                               ->
                                  let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                  h2_respond_json h2_reqd body
                                    ~status:`Not_found
                                    ~extra_headers:initial_mcp_headers
                             | Error
                                 (Server_mcp_request_context.Invalid_accept msg)
                               ->
                                 let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:initial_mcp_headers
                             | Error
                                 (Server_mcp_request_context.Header_mismatch msg)
                               ->
                                 let body =
                                   Printf.sprintf
                                     {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"},"id":null}|}
                                     (String.escaped msg)
                                 in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:initial_mcp_headers
                             | Ok post_context ->
                                 (match
                                    Server_mcp_transport_http
                                    .begin_mcp_session_operation transport
                                      ~session_id
                                      ~requester:admission.identity
                                      ~require_known:context.session_was_provided
                                  with
                                  | Error lifecycle_error ->
                                      h2_respond_mcp_lifecycle_error h2_reqd
                                        ~extra_headers:initial_mcp_headers
                                        lifecycle_error
                                  | Ok operation ->
                                      Fun.protect
                                        ~finally:(fun () ->
                                          Server_mcp_transport_http
                                          .finish_mcp_session_operation transport
                                            operation)
                                        (fun () ->
                                 let otel_transport_context =
                                   Otel_dispatch_hook.http_transport_context
                                     ~protocol_version:"2"
                                 in
                                 with_server_state h2_reqd (fun state ->
                                   let mcp_eio_profile =
                                     mcp_eio_profile_of_transport_profile profile
                                   in
                                   let body_with_agent =
                                     Server_mcp_transport_http.body_with_canonical_http_actor
                                       ~base_path ~auth_token httpun_request
                                       post_context.body_str
                                   in
                                   let internal_keeper_runtime =
                                     Server_auth.is_verified_internal_keeper_request
                                       ~base_path httpun_request
                                   in
                                   let response_json =
                                     let otel_transport_context =
                                       Otel_dispatch_hook.http_transport_context
                                         ~protocol_version:"2"
                                     in
                                     Mcp_eio.handle_request ~clock ~sw
                                       ~profile:mcp_eio_profile
                                       ~mcp_session_id:session_id ?auth_token
                                       ~otel_mcp_protocol_version:protocol_version
                                       ~otel_transport_context
                                       ~internal_keeper_runtime state
                                       body_with_agent
                                   in
                                   let response_json, initialized =
                                     match
                                       Server_mcp_transport_http
                                       .commit_successful_initialize ~sessions
                                         ~session_id ~profile
                                         ~requester:admission.identity
                                         ~otel_transport_context
                                         ~request_body:post_context.body_str
                                         ~response_json
                                     with
                                     | Ok Server_mcp_transport_http.Not_initialize ->
                                         response_json, false
                                     | Ok Server_mcp_transport_http.Initialized ->
                                         response_json, true
                                     | Error store_error ->
                                         let message =
                                           Server_mcp_transport_http.Store
                                           .mutation_error_to_string store_error
                                         in
                                         Log.Server.error
                                           "H2 MCP initialize session commit failed: session=%s error=%s"
                                           session_id message;
                                         ( Mcp_transport_protocol.make_error
                                             ~id:
                                               (Option.value ~default:`Null
                                                  (Server_mcp_transport_http
                                                   .body_jsonrpc_id
                                                     post_context.body_str))
                                             (Mcp_error_code.to_wire_code
                                                Mcp_error_code.Internal_error)
                                             "MCP session initialization could not be committed."
                                         , false )
                                   in
                                   let protocol_version =
                                     get_protocol_version_for_session ~sessions
                                       ~session_id httpun_request
                                   in
                                   let mcp_hdrs =
                                     let visibility =
                                       Server_mcp_transport_http_headers
                                       .session_header_visibility
                                         ~session_was_provided:
                                           context.session_was_provided
                                         ~initialized
                                     in
                                     cors
                                     @ Server_mcp_transport_http_headers
                                       .mcp_response_headers ~visibility
                                         ~session_id ~protocol_version
                                   in
                                   match response_json with
                                   | `Null ->
                                       h2_respond_empty h2_reqd ~status:`Accepted
                                         ~extra_headers:
                                           (("content-type", "application/json")
                                            :: mcp_hdrs)
                                   | json when is_http_error_response json ->
                                       h2_respond_json_value h2_reqd json ~status:`Bad_request
                                         ~extra_headers:mcp_hdrs
                                   | json ->
                                       h2_respond_json_value h2_reqd json ~extra_headers:mcp_hdrs))))))))))

      | `DELETE, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `DELETE, "/mcp" | `DELETE, "/mcp/managed" ->
          with_server_state h2_reqd (fun state ->
            with_mcp_http_transport h2_reqd state (fun transport ->
            let sessions =
              Server_mcp_transport_http.mcp_transport_sessions transport
            in
            let profile =
              if String.equal path "/mcp/managed" then
                Server_mcp_transport_http.Managed_agent
              else Server_mcp_transport_http.Full
            in
            let base_path = (Mcp_server.workspace_config state).base_path in
            match
              Server_mcp_transport_http.authorize_mcp_profile_admission
                ~base_path ~profile httpun_request
            with
            | Error err -> h2_respond_auth_error h2_reqd err
            | Ok admission -> (
                match session_id_opt with
                | None ->
                    h2_respond_text h2_reqd "Mcp-Session-Id required"
                      ~status:`Bad_request ~extra_headers:cors
                | Some session_id ->
                    let protocol_version =
                      get_protocol_version_for_session ~sessions ~session_id
                        httpun_request
                    in
                    let perform_delete () =
                      let sse_active_before_stop =
                        Server_mcp_transport_http.is_active_sse_session
                          session_id
                      in
                      match
                        Server_mcp_transport_http.delete_mcp_session ~transport
                          ~session_id ~requester:admission.identity
                      with
                      | Error
                          (Server_mcp_transport_http.Delete_not_authorized msg)
                        ->
                          h2_respond_json h2_reqd
                            (json_rpc_error Mcp_error_code.Auth_error msg)
                            ~status:`Forbidden ~extra_headers:cors
                      | Error delete_error ->
                          h2_respond_json h2_reqd
                            (json_rpc_error Mcp_error_code.Internal_error
                               (Server_mcp_transport_http
                                .mcp_session_delete_error_to_string
                                  delete_error))
                            ~status:`Internal_server_error ~extra_headers:cors
                      | Ok () ->
                          Log.H2_gateway.info
                            "Session terminated: %s reason=client_delete \
                             profile=%s protocol_version=%s \
                             sse_active_before_stop=%b \
                             resource_cleanup=cleared"
                            session_id
                            (Server_mcp_transport_http.profile_label profile)
                            protocol_version sse_active_before_stop;
                          h2_respond_empty h2_reqd
                            ~extra_headers:
                              (mcp_headers session_id protocol_version)
                    in
                    let validate_fresh_delete () =
                      match
                        Server_mcp_transport_http.authorize_mcp_session_delete
                          ~sessions ~session_id ~requester:admission.identity
                      with
                      | Error msg ->
                          h2_respond_json h2_reqd
                            (json_rpc_error Mcp_error_code.Auth_error msg)
                            ~status:`Forbidden ~extra_headers:cors
                      | Ok () -> (
                          match
                            validate_mcp_session_delete_profile ~sessions
                              ~profile session_id
                          with
                          | Error msg ->
                              h2_respond_json h2_reqd
                                (json_rpc_error Mcp_error_code.Invalid_request
                                   msg)
                                ~status:`Conflict ~extra_headers:cors
                          | Ok () -> (
                              match
                                Server_mcp_transport_http
                                .validate_protocol_version_continuity
                                  ~sessions ~session_id httpun_request
                              with
                              | Error msg ->
                                  h2_respond_json h2_reqd
                                    (json_rpc_error
                                       Mcp_error_code.Invalid_request msg)
                                    ~status:`Bad_request
                                    ~extra_headers:
                                      (cors
                                      @ mcp_headers session_id protocol_version)
                              | Ok () -> perform_delete ()))
                    in
                    match
                      Server_mcp_transport_http
                      .retained_mcp_session_delete_authorization transport
                        ~session_id
                        ~requester:admission.identity
                    with
                    | Server_mcp_transport_http.Retained_delete_authorized ->
                        perform_delete ()
                    | Server_mcp_transport_http.Retained_delete_rejected
                        { message } ->
                        h2_respond_json h2_reqd
                          (json_rpc_error Mcp_error_code.Auth_error message)
                          ~status:`Forbidden ~extra_headers:cors
                    | Server_mcp_transport_http.Retained_delete_in_progress ->
                        h2_respond_json h2_reqd
                          (json_rpc_error Mcp_error_code.Invalid_request
                             (Printf.sprintf
                                "MCP session %s deletion is already in progress."
                                session_id))
                          ~status:`Conflict ~extra_headers:cors
                    | Server_mcp_transport_http.No_retained_delete ->
                        validate_fresh_delete ())))

      (* ─────────────────────────────────────────────────────────────────────
         Dashboard
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/dashboard" | `GET, "/dashboard/" ->
          h2_respond_dashboard_index ()

      | `GET, p when is_dashboard_spa_deep_link p ->
          h2_respond_dashboard_index ()

      (* ─────────────────────────────────────────────────────────────────────
         GraphQL
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/graphql" ->
          with_h2_read_auth h2_reqd (fun _state ->
            let nonce =
              let rng = Random.State.make_self_init () in
              let bytes =
                Bytes.init 16 (fun _ -> Char.chr (Random.State.int rng 256))
              in
              Base64.encode_string (Bytes.to_string bytes)
            in
            let csp_header =
              "content-security-policy", graphql_csp_header nonce
            in
            h2_respond_html h2_reqd (graphql_playground_html ~nonce)
              ~extra_headers:(csp_header :: cors))

      | `POST, "/graphql" ->
          with_h2_read_auth h2_reqd (fun state ->
            h2_read_body h2_reqd (fun body_str ->
              let response = Graphql_api.handle_request ~config:(Mcp_server.workspace_config state) body_str in
              let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
              h2_respond_json h2_reqd response.body ~status ~extra_headers:cors))

      (* ─────────────────────────────────────────────────────────────────────
         REST API
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/api/v1/dashboard" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              `Assoc
                [
                  ("error", `String "dashboard batch contract removed");
                  ("message", `String "Use /api/v1/dashboard/shell and surface-specific projection endpoints.");
                ]
            in
            h2_respond_json_value h2_reqd json
              ~status:`Gone ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/shell" ->
          with_h2_public_read h2_reqd (fun state ->
            let light =
              Server_utils.bool_query_param httpun_request "light" ~default:false
            in
            let json =
              dashboard_shell_http_json ?clock:state.Mcp_server.clock
                ~request:httpun_request ~light
                (Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/branches" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Dashboard_branches.json ~config:(Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/nudges" ->
          with_h2_public_read h2_reqd (fun state ->
            let limit =
              Server_utils.int_query_param httpun_request "limit" ~default:50
              |> Server_utils.clamp ~min_v:1 ~max_v:200
            in
            let json =
              Dashboard_operator_nudges.json
                ~config:(Mcp_server.workspace_config state) ~limit ()
            in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/workspace" ->
          with_h2_public_read h2_reqd (fun state ->
            let limit =
              Server_utils.int_query_param httpun_request "limit" ~default:50
              |> Server_utils.clamp ~min_v:1 ~max_v:200
            in
            let me =
              match trimmed_query_param httpun_request "me" with
              | Some _ as value -> value
              | None -> trimmed_query_param httpun_request "agent"
            in
            let json =
              Dashboard_workspace.json ~config:(Mcp_server.workspace_config state) ?me
                ~limit ()
            in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/config" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json = Env_config_introspect.to_json () in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/config/excuse-patterns" ->
          with_h2_public_read h2_reqd (fun _state ->
            let patterns = Task.Anti_rationalization.load_excuse_patterns () in
            let json_items = List.map (fun (pat, reason) -> `List [`String pat; `String reason]) patterns in
            let json = `List json_items in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `POST, "/api/v1/dashboard/config/excuse-patterns" ->
          with_h2_token_permission_auth h2_reqd ~permission:Masc_domain.CanAdmin
            (fun _state _agent_name ->
              h2_read_body h2_reqd (fun body_str ->
                try
                  let json = Yojson.Safe.from_string body_str in
                  match Task.Anti_rationalization.parse_excuse_patterns_json json with
                  | Error msg ->
                      h2_respond_json_value
                        h2_reqd
                        (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
                        ~status:`Bad_request
                        ~extra_headers:cors
                  | Ok patterns ->
                      (match Task.Anti_rationalization.save_excuse_patterns patterns with
                       | Ok () ->
                           h2_respond_json_value h2_reqd
                             (`Assoc [ ("ok", `Bool true) ])
                             ~extra_headers:cors
                       | Error msg ->
                           h2_respond_json_value
                             h2_reqd
                             (`Assoc
                                [ ("ok", `Bool false); ("error", `String msg) ])
                             ~status:`Internal_server_error
                             ~extra_headers:cors)
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | _exn ->
                    h2_respond_json_value
                      h2_reqd
                      (`Assoc
                         [
                           ("ok", `Bool false);
                           ("error", `String "Invalid JSON body");
                         ])
                      ~status:`Bad_request
                      ~extra_headers:cors))

      | `GET, "/api/v1/dashboard/project-snapshot"
      | `GET, "/api/v1/dashboard/namespace-truth" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              (* RFC-0138 Phase 3 Step 3 follow-up — route H/2 gateway
                 through the snapshot selector for parity with the H/1
                 router (see server_routes_http_routes_dashboard.ml).
                 Without this, H/2 clients bypass Dashboard_snapshot
                 entirely and the cold-start fallback claim is false. *)
              Server_dashboard_snapshot_select.select_project_snapshot_json
                ~state ~sw ~clock httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/execution" ->
          with_h2_public_read h2_reqd (fun state ->
            match dashboard_execution_cached_http_body ~state httpun_request with
            | Some body ->
              h2_respond_json h2_reqd body ~compress:false ~extra_headers:cors
            | None ->
              let json = dashboard_execution_http_json ~state ~sw ~clock httpun_request in
              h2_respond_json_value h2_reqd json ~compress:false ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/execution-trust" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_execution_trust_http_json ~state ~sw ~clock
                httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/board" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json = dashboard_memory_http_json httpun_request in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/governance" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_governance_http_json httpun_request
                ~base_path:(Mcp_server.workspace_config state).base_path
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/proof" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_proof_http_json
                ~config:(Mcp_server.workspace_config state) httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/planning" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_planning_http_json
                ~config:(Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/bootstrap" ->
          (* Same SSOT as the HTTP/1.1 router so the HTTP/2 client sees
             the identical payload shape, slice list, and error
             contract.  See [Server_dashboard_http.dashboard_bootstrap_http_json]. *)
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_bootstrap_http_json ~state ~sw ~clock httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/goals" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_goals_tree_http_json
                ~config:(Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/goals/detail" ->
          with_h2_public_read h2_reqd (fun state ->
            let goal_id =
              match Server_utils.query_param httpun_request "goal_id" with
              | Some value -> String.trim value
              | None -> ""
            in
            if goal_id = "" then
              h2_respond_json_value h2_reqd
                (`Assoc
                   [
                     ("ok", `Bool false);
                     ("error", `String "goal_id query param is required");
                   ])
                ~status:`Bad_request ~extra_headers:cors
            else
              let json =
                dashboard_goal_detail_http_json
                  ~config:(Mcp_server.workspace_config state) ~goal_id
              in
              h2_respond_json_value h2_reqd json
                ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/tasks/history" ->
          with_h2_public_read h2_reqd (fun state ->
            let task_id =
              match Server_utils.query_param httpun_request "task_id" with
              | Some value -> String.trim value
              | None -> ""
            in
            if task_id = "" then
              h2_respond_json_value h2_reqd
                (`Assoc [ ("error", `String "task_id is required") ])
                ~status:`Bad_request ~extra_headers:cors
            else
              let limit =
                Server_utils.int_query_param httpun_request "limit" ~default:50
                |> Server_utils.clamp ~min_v:1 ~max_v:200
              in
              let json =
                Task.Tool.task_history_events_json (Mcp_server.workspace_config state)
                  ~task_id ~limit
              in
              h2_respond_json_value h2_reqd json
                ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/briefing" ->
          with_h2_public_read h2_reqd (fun state ->
            let json = dashboard_briefing_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/session" ->
          with_h2_public_read h2_reqd (fun state ->
            let json = dashboard_session_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/briefing/sections" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_briefing_sections_http_json ~state ~sw ~clock
                httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/transport-health" ->
          with_h2_public_read h2_reqd (fun state ->
            let json = dashboard_transport_health_http_json ~state in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/perf" ->
          with_h2_public_read h2_reqd (fun state ->
            let json = dashboard_perf_http_json (Mcp_server.workspace_config state) in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/oas/telemetry/recent" ->
          with_h2_public_read h2_reqd (fun _state ->
            let provider = oas_telemetry_provider_param httpun_request in
            let limit = oas_telemetry_limit_param httpun_request in
            let json = Dashboard_oas_bridge.recent_json ?provider ~limit () in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/oas/telemetry/summary" ->
          with_h2_public_read h2_reqd (fun _state ->
            let provider = oas_telemetry_provider_param httpun_request in
            let limit = oas_telemetry_limit_param httpun_request in
            let json = Dashboard_oas_bridge.summary_json ?provider ~limit () in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      | `GET, p when String.starts_with ~prefix:"/api/v1/command-plane" p ->
          h2_respond_removed_surface h2_reqd ~surface:"command_plane" ~extra_headers:cors

      | `GET, "/api/v1/status" ->
          with_h2_public_read h2_reqd (fun state ->
            let config = (Mcp_server.workspace_config state) in
            let workspace_state = Workspace.read_state config in
            let tempo = Tempo.get_tempo config in
            let json = `Assoc [
              ("cluster", `String (Env_config_core.cluster_name ()));
              ("project", `String workspace_state.project);
              ("tempo_interval_s", `Float tempo.current_interval_s);
              ("paused", `Bool workspace_state.paused);
            ] in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/openapi.json" ->
          with_h2_public_read h2_reqd (fun _state ->
          let host_header = get_header_any_case httpun_request.headers "host" in
          let (resolved_host, resolved_port) = match host_header with
            | Some header -> parse_host_port (Some header)
                (Env_config_core.masc_host ()) (Env_config_core.masc_http_port_int ())
            | None -> ("", 0)
          in
          let json =
            Transport.Rest.generate_openapi_document
              ~host:resolved_host ~port:resolved_port ()
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/namespace/current"
      | `GET, "/api/v1/workspace/current"
      | `POST, "/api/v1/namespace/current"
      | `POST, "/api/v1/workspace/current" ->
          h2_respond_removed_surface h2_reqd ~surface:"namespace" ~extra_headers:cors

      | `POST, p when String.starts_with ~prefix:"/api/v1/command-plane" p ->
          h2_respond_removed_surface h2_reqd ~surface:"command_plane" ~extra_headers:cors

      (* ═══════════════════════════════════════════════════════════════════════
         Delegated route groups
         ═══════════════════════════════════════════════════════════════════════ *)
      | _
        when Server_h2_gateway_routes_extra.dispatch
               ~with_public_read:(fun respond ->
                 with_h2_public_read h2_reqd (fun _state -> respond ()))
               ~h2_reqd ~httpun_request
               ~cors ~path
               ~config:
                 (Option.map
                    (fun state -> (Mcp_server.workspace_config state))
                    !server_state)
               httpun_meth ->
          ()

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    try
      if is_mcp_like_path path && not (validate_origin httpun_request)
      then
        h2_respond_json h2_reqd
          (json_rpc_error Mcp_error_code.Invalid_request "Invalid origin")
          ~status:`Forbidden ~extra_headers:cors
      else dispatch_h2_route ()
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
