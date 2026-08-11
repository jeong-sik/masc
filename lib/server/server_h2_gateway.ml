
open Masc_domain
open Server_auth
open Server_dashboard_http
open Server_h2_gateway_helpers
open Server_routes_http

let h2_request_authority_bad_request ~error_code ~message h2_reqd =
  h2_respond_json_value
    h2_reqd
    (`Assoc [ "error_code", `String error_code; "error", `String message ])
    ~status:`Bad_request
;;

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

let make_request_handler ~trust_policy ~sw ~clock ~server_start_time:_ =
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

  let agent_core_telemetry_limit_param req =
    Server_utils.int_query_param req "limit" ~default:50
    |> Server_utils.clamp ~min_v:1 ~max_v:200
  in

  let agent_core_telemetry_provider_param req =
    trimmed_query_param req "provider"
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
    let handle_admitted_request request_authority =
    let path = Http.Request.path httpun_request in
    let origin = get_origin httpun_request in
    let reflected_cors_origin =
      public_read_cors_origin_opt ~request_authority httpun_request
    in
    let cors =
      match reflected_cors_origin with
      | Some origin -> cors_headers origin
      | None -> [ "vary", "Origin" ]
    in
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
    let h2_respond_auth_error h2_reqd err =
      let status = http_status_of_auth_error err in
      h2_respond_json
        h2_reqd
        (auth_error_json err)
        ~status:(status :> H2.Status.t)
        ~extra_headers:(auth_error_headers ~status ~cors)
    in
    let mcp_auth_error_body failure =
      Server_mcp_transport_http_respond.error_body
        ?data:(Server_mcp_transport_http_protocol.auth_failure_data failure)
        ~code:Mcp_error_code.Auth_error
        failure.message
      |> Yojson.Safe.to_string
    in
    let h2_respond_oauth_error error =
      Log.Misc.warn
        "oauth_http: request rejected error=%s"
        (Auth_oauth.protocol_error_code error);
      h2_respond_json_value
        h2_reqd
        (Server_oauth_service.oauth_error_json error)
        ~status:(Server_oauth_service.oauth_error_status error :> H2.Status.t)
        ~extra_headers:[ "cache-control", "no-store"; "pragma", "no-cache" ]
    in
    let with_h2_oauth f =
      if Auth_oauth.enabled () && Server_oauth_metadata.loopback_authority request_authority
      then f ()
      else h2_respond_text h2_reqd "Not Found" ~status:`Not_found
    in
    let with_h2_oauth_base_path f =
      with_h2_oauth (fun () ->
        match get_server_state_result () with
        | Ok state -> f (Mcp_server.workspace_config state).base_path
        | Error _ -> h2_respond_oauth_error Auth_oauth.Temporarily_unavailable)
    in
    let h2_respond_oauth_form ?(status = `OK) ?error authorization_request =
      h2_respond_html
        h2_reqd
        (Server_oauth_service.render_authorization_form ?error authorization_request)
        ~status
        ~extra_headers:Server_oauth_service.authorization_form_headers
    in
    let h2_respond_oauth_redirect location =
      h2_respond_empty
        h2_reqd
        ~status:`Found
        ~extra_headers:
          [ "location", location; "cache-control", "no-store" ]
    in
    let h2_read_oauth_body callback =
      let body = H2.Reqd.request_body h2_reqd in
      let buffer = Http_body_buffer.create 4096 in
      let bytes_read = ref 0 in
      let stopped = ref false in
      let rec read_loop () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            if not !stopped then callback (Http_body_buffer.contents buffer))
          ~on_read:(fun bigstring ~off ~len ->
            bytes_read := !bytes_read + len;
            if !bytes_read > Server_oauth_service.max_request_body_bytes
            then (
              stopped := true;
              H2.Body.Reader.close body;
              h2_respond_oauth_error
                (Auth_oauth.Invalid_request "request body is too large"))
            else (
              Http_body_buffer.add_bigstring buffer bigstring ~off ~len;
              read_loop ()))
      in
      read_loop ()
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
    let with_h2_public_read h2_reqd f =
      let with_initialized_state f =
        match get_server_state_result () with
        | Ok state -> f state
        | Error _message ->
            h2_respond_json h2_reqd
              (not_initialized_response path)
              ~extra_headers:cors
      in
      (* Match H1 [with_public_read]: a route that selected this wrapper is
         public by declaration.  Do not run a second global allowlist or let
         a stale bearer change a read-only Dashboard response into 401/403. *)
      with_initialized_state f
    in
    let h2_respond_ide_public_read response =
      let extra_headers = response.Server_ide_http.extra_headers @ cors in
      match response.status with
      | `OK ->
        h2_respond_json_value
          h2_reqd
          response.body
          ~compress:response.compress
          ~extra_headers
      | `Bad_request ->
        h2_respond_json_value
          h2_reqd
          response.body
          ~status:`Bad_request
          ~compress:response.compress
          ~extra_headers
    in
    let h2_respond_ide_public_mutation response =
      match response.Server_ide_http.status, response.body with
      | `No_content, _ ->
          h2_respond_empty h2_reqd ~status:`No_content ~extra_headers:cors
      | (`Created | `Bad_request | `Internal_server_error as status), Some body ->
          h2_respond_json_value h2_reqd body ~status ~extra_headers:cors
      | (`Created | `Bad_request | `Internal_server_error), None ->
          h2_respond_empty h2_reqd ~status:`Internal_server_error ~extra_headers:cors
    in
    let with_h2_token_permission_auth h2_reqd ~permission f =
      let _ = permission in
      with_h2_public_read h2_reqd (fun state -> f state "dashboard")
    in
    let with_h2_keeper_get_auth h2_reqd ~permission f =
      with_server_state h2_reqd (fun state ->
        match
          Server_auth.authorize_token_bound_permission_request
            ~base_path:(Mcp_server.workspace_config state).base_path
            ~permission
            httpun_request
        with
        | Ok agent_name ->
            (match h2_check_agent_rate_limit h2_reqd with
             | Ok () -> f state agent_name
             | Error () -> ())
        | Error error -> h2_respond_auth_error h2_reqd error)
    in
    (* H2 counterpart of [Server_auth.with_read_auth]: authorize on every
       request.  It remains distinct from [with_h2_public_read], which is an
       intentionally anonymous route-local read surface on both transports. *)
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
    let h2_respond_board_reaction_result h2_reqd = function
      | Ok json -> h2_respond_json_value h2_reqd json ~extra_headers:cors
      | Error error ->
        h2_respond_json_value
          h2_reqd
          (Server_board_reaction_http.error_json error)
          ~status:(Server_board_reaction_http.error_status error :> H2.Status.t)
          ~extra_headers:cors
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

    let _h2_authorize_tool state ~tool_name =
      authorize_tool_request
        ~base_path:(Mcp_server.workspace_config state).base_path
        ~tool_name ~request_authority httpun_request
    in

    let dispatch_h2_route () =
      match httpun_meth, path with
      (* ─────────────────────────────────────────────────────────────────────
         Health & Metrics
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/health" ->
          let json =
            Server_routes_http_runtime.make_health_response_json
              ~listener:"h2"
              ~request_authority
              httpun_request
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
          let current = Server_startup_state.snapshot () in
          let json, status =
            if current.state_ready then
              (`Assoc [
                 ("ready", `Bool true);
                 ("phase", `String (Server_startup_state.phase_to_string current.phase));
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
          h2_respond_json_value h2_reqd
            (Server_routes_http_runtime.agent_card_json
               ~request_authority
               httpun_request)
            ~extra_headers:cors

      | `GET,
        ( "/.well-known/oauth-protected-resource"
        | "/.well-known/oauth-protected-resource/mcp"
        | "/mcp/.well-known/oauth-protected-resource" ) ->
          with_h2_oauth (fun () ->
            h2_respond_json_value
              h2_reqd
              (Server_oauth_metadata.protected_resource_json request_authority)
              ~extra_headers:[ "cache-control", "no-store" ])

      | `GET, "/.well-known/oauth-authorization-server" ->
          with_h2_oauth (fun () ->
            h2_respond_json_value
              h2_reqd
              (Server_oauth_metadata.authorization_server_json request_authority)
              ~extra_headers:[ "cache-control", "no-store" ])

      | `GET, "/oauth/authorize" ->
          with_h2_oauth_base_path (fun base_path ->
            match
              Server_oauth_service.authorize_get
                ~base_path
                ~authority:request_authority
                ~target:httpun_request.Httpun.Request.target
            with
            | Error error -> h2_respond_oauth_error error
            | Ok authorization_request ->
              h2_respond_oauth_form authorization_request)

      | `POST, "/oauth/authorize" ->
          with_h2_oauth_base_path (fun base_path ->
            match
              ensure_same_origin_browser_request
                ~request_authority
                httpun_request
            with
            | Error error -> h2_respond_auth_error h2_reqd error
            | Ok () ->
              h2_read_oauth_body (fun body ->
                match
                  Server_oauth_service.authorize_post
                    ~base_path
                    ~authority:request_authority
                    ~body
                with
                | Error error -> h2_respond_oauth_error error
                | Ok
                    (Server_oauth_service.Authorization_form_error
                      { status; message; request = authorization_request }) ->
                  h2_respond_oauth_form
                    ~status:(status :> H2.Status.t)
                    ~error:message
                    authorization_request
                | Ok (Server_oauth_service.Authorization_redirect location) ->
                  h2_respond_oauth_redirect location))

      | `POST, "/oauth/register" ->
          with_h2_oauth_base_path (fun base_path ->
            match
              ensure_same_origin_if_browser_request
                ~request_authority
                httpun_request
            with
            | Error error -> h2_respond_auth_error h2_reqd error
            | Ok () ->
              h2_read_oauth_body (fun body ->
                match Server_oauth_service.register_client ~base_path body with
                | Error error -> h2_respond_oauth_error error
                | Ok client ->
                  Log.Misc.info "oauth_http: dynamic client registered";
                  h2_respond_json_value
                    h2_reqd
                    (Server_oauth_service.registered_client_json client)
                    ~status:`Created
                    ~extra_headers:[ "cache-control", "no-store" ]))

      | `POST, "/oauth/token" ->
          with_h2_oauth_base_path (fun base_path ->
            match
              ensure_same_origin_if_browser_request
                ~request_authority
                httpun_request
            with
            | Error error -> h2_respond_auth_error h2_reqd error
            | Ok () ->
              h2_read_oauth_body (fun body ->
                match
                  Server_oauth_service.token
                    ~base_path
                    ~authority:request_authority
                    ~body
                with
                | Error error -> h2_respond_oauth_error error
                | Ok pair ->
                  Log.Misc.info "oauth_http: token grant completed";
                  h2_respond_json_value
                    h2_reqd
                    (Server_oauth_service.token_pair_json pair)
                    ~extra_headers:
                      [ "cache-control", "no-store"; "pragma", "no-cache" ]))

      | `GET, "/ws" ->
          let json =
            Server_routes_http_runtime.websocket_discovery_json
              ~request_authority
              httpun_request
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors

      | `POST, "/webrtc/offer" ->
          if not (Server_webrtc_transport.is_enabled ()) then
            h2_respond_json_value h2_reqd
              (`Assoc [ ("error", `String "webrtc transport disabled") ])
              ~status:`Not_found ~extra_headers:cors
          else
            with_server_state h2_reqd (fun state ->
              match
                authorize_permission_request
                  ~base_path:(Mcp_server.workspace_config state).base_path
                  ~permission:Masc_domain.CanBroadcast
                  httpun_request
              with
              | Error err ->
                  let status = http_status_of_auth_error err in
                  h2_respond_json
                    h2_reqd
                    (auth_error_json err)
                    ~status:(status :> H2.Status.t)
                    ~extra_headers:(auth_error_headers ~status ~cors)
              | Ok () ->
                  h2_read_body h2_reqd (fun body_str ->
                    match Server_webrtc_transport.handle_offer_request body_str with
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
            with_server_state h2_reqd (fun state ->
              match
                authorize_permission_request
                  ~base_path:(Mcp_server.workspace_config state).base_path
                  ~permission:Masc_domain.CanBroadcast
                  httpun_request
              with
              | Error err ->
                  let status = http_status_of_auth_error err in
                  h2_respond_json
                    h2_reqd
                    (auth_error_json err)
                    ~status:(status :> H2.Status.t)
                    ~extra_headers:(auth_error_headers ~status ~cors)
              | Ok () ->
                  h2_read_body h2_reqd (fun body_str ->
                    match Server_webrtc_transport.handle_answer_request body_str with
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
          let headers =
            match reflected_cors_origin with
            | Some reflected -> cors_preflight_headers reflected
            | None -> [ "vary", "Origin" ]
          in
          h2_respond_empty h2_reqd ~extra_headers:headers

      (* ─────────────────────────────────────────────────────────────────────
         MCP Endpoints
         ───────────────────────────────────────────────────────────────────── *)
      | `POST, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `POST, "/mcp" | `POST, "/" | `POST, "/mcp/managed" ->
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
          let base_path = match current_server_state () with
            | Some s -> (Mcp_server.workspace_config s).base_path
            | None -> default_base_path ()
          in
          let context =
            Server_mcp_request_context.make ~session_id_opt
              ~generated_session_id:session_id
              ~auth_token:(auth_token_from_request httpun_request)
              ~protocol_version:
                (get_protocol_version_for_session ~session_id httpun_request)
              ~origin ~base_path
          in
          let session_id = context.session_id in
          let auth_token = context.auth_token in
          let protocol_version = context.protocol_version in
          let auth_result =
            match profile with
            | Server_mcp_transport_http.Full
            | Server_mcp_transport_http.Managed_agent ->
                verify_mcp_auth ~base_path httpun_request
                |> Result.map_error
                     Server_mcp_transport_http_types.auth_failure_of_masc_error
            | Server_mcp_transport_http.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
                |> Result.map_error
                     Server_mcp_transport_http_types.auth_failure_of_masc_error
          in
          (match validate_mcp_session_profile ~profile session_id with
           | Error msg ->
               let body = json_rpc_error Mcp_error_code.Invalid_request msg in
               h2_respond_json h2_reqd body ~status:`Conflict ~extra_headers:cors
           | Ok () ->
               (match Server_mcp_transport_http.validate_protocol_version_continuity
                        ~session_id httpun_request with
                | Error msg ->
                    let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                    h2_respond_json h2_reqd body ~status:`Bad_request
                      ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                | Ok () ->
                    (match auth_result with
                     | Error failure ->
                         let body = mcp_auth_error_body failure in
                         h2_respond_json h2_reqd body ~status:`Unauthorized
                           ~extra_headers:
                             (( "www-authenticate"
                              , Server_oauth_metadata.challenge_for_authority
                                  request_authority )
                              :: cors)
                     | Ok _cred_opt ->
                         let otel_transport_context =
                           Otel_dispatch_hook.http_transport_context
                             ~protocol_version:"2"
                         in
                         remember_mcp_profile
                           ~otel_transport_context
                           session_id
                           profile;
                         h2_read_body h2_reqd (fun body_str ->
                             match
                               Server_mcp_request_context.decide_post_body
                                 ~request:httpun_request ~context
                                 ~session_is_known:
                                   (Server_mcp_transport_http.is_known_session
                                      session_id)
                                 body_str
                             with
                             | Error
                                 (Server_mcp_request_context.Session_required msg)
                               ->
                                 let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                 h2_respond_json h2_reqd body
                                   ~status:`Bad_request
                                   ~extra_headers:
                                     (cors
                                     @ mcp_headers session_id
                                         protocol_version)
                             | Error
                                 (Server_mcp_request_context.Unknown_session msg)
                               ->
                                  let new_session_id = Mcp_session.generate () in
                                  let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                  h2_respond_json h2_reqd body
                                    ~status:`Not_found
                                    ~extra_headers:
                                      (cors
                                      @ mcp_headers new_session_id
                                          protocol_version)
                             | Error
                                 (Server_mcp_request_context.Invalid_accept msg)
                               ->
                                 let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                             | Error
                                 (Server_mcp_request_context.Header_mismatch msg)
                               ->
                                 let body =
                                   Printf.sprintf
                                     {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"},"id":null}|}
                                     (String.escaped msg)
                                 in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                             | Ok post_context ->
                                 with_server_state h2_reqd (fun state ->
                                   let profile =
                                     mcp_eio_profile_of_transport_profile profile
                                   in
                                   let response_json =
                                     let otel_transport_context =
                                       Otel_dispatch_hook.http_transport_context
                                         ~protocol_version:"2"
                                     in
                                     let expected_resource =
                                       Server_oauth_metadata.resource request_authority
                                     in
                                     Auth_oauth.with_expected_resource
                                       expected_resource
                                       (fun () ->
                                         let body_with_agent =
                                           Server_mcp_transport_http.body_with_canonical_http_actor
                                             ~base_path ~auth_token httpun_request
                                             post_context.body_str
                                         in
                                         let internal_keeper_runtime =
                                           Server_auth.is_verified_internal_keeper_request
                                             ~base_path httpun_request
                                         in
                                         Mcp_eio.handle_request ~clock ~sw ~profile
                                           ~mcp_session_id:session_id ?auth_token
                                           ~otel_mcp_protocol_version:protocol_version
                                           ~otel_transport_context
                                           ~internal_keeper_runtime state
                                           body_with_agent)
                                   in
                                   let otel_transport_context =
                                     Otel_dispatch_hook.http_transport_context
                                       ~protocol_version:"2"
                                   in
                                   remember_protocol_version_if_initialize_succeeded
                                     ~otel_transport_context
                                     session_id
                                     ~request_body:post_context.body_str
                                     ~response_json;
                                   let protocol_version =
                                     get_protocol_version_for_session ~session_id
                                       httpun_request
                                   in
                                   let mcp_hdrs =
                                     mcp_headers session_id protocol_version @ cors
                                   in
                                   match response_json with
                                   | `Null ->
                                       h2_respond_empty h2_reqd ~status:`Accepted
                                         ~extra_headers:mcp_hdrs
                                   | json when is_http_error_response json ->
                                       h2_respond_json_value h2_reqd json ~status:`Bad_request
                                         ~extra_headers:mcp_hdrs
                                   | json ->
                                       h2_respond_json_value h2_reqd json ~extra_headers:mcp_hdrs)))))

      | `DELETE, "/mcp/operator" ->
          h2_respond_removed_surface h2_reqd ~surface:"operator_remote" ~extra_headers:cors

      | `DELETE, "/mcp" | `DELETE, "/mcp/managed" ->
          let profile =
            if String.equal path "/mcp/managed"
            then Server_mcp_transport_http.Managed_agent
            else Server_mcp_transport_http.Full
          in
          let base_path = match current_server_state () with
            | Some s -> (Mcp_server.workspace_config s).base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Server_mcp_transport_http.Full
            | Server_mcp_transport_http.Managed_agent ->
                verify_mcp_auth ~base_path httpun_request
                |> Result.map_error
                     Server_mcp_transport_http_types.auth_failure_of_masc_error
            | Server_mcp_transport_http.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
                |> Result.map_error
                     Server_mcp_transport_http_types.auth_failure_of_masc_error
          in
          (match auth_result with
           | Error failure ->
               let body = mcp_auth_error_body failure in
               h2_respond_json h2_reqd body ~status:`Unauthorized
                 ~extra_headers:
                   (( "www-authenticate"
                    , Server_oauth_metadata.challenge_for_authority
                        request_authority )
                    :: cors)
           | Ok _ ->
               (match session_id_opt with
                | Some session_id -> (
                    match validate_mcp_session_delete_profile ~profile session_id with
                    | Error msg ->
                        let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                        h2_respond_json h2_reqd body ~status:`Conflict
                          ~extra_headers:cors
                    | Ok () ->
                        (match Server_mcp_transport_http.validate_protocol_version_continuity
                                 ~session_id httpun_request with
                         | Error msg ->
                             let body = json_rpc_error Mcp_error_code.Invalid_request msg in
                             h2_respond_json h2_reqd body ~status:`Bad_request
                               ~extra_headers:(cors @ mcp_headers session_id (get_protocol_version httpun_request))
                         | Ok () ->
                             let protocol_version =
                               get_protocol_version httpun_request
                             in
                             let sse_active_before_stop =
                               Server_mcp_transport_http.is_active_sse_session
                                 session_id
                             in
                             stop_sse_session session_id;
                             Sse.unregister session_id;
                             forget_mcp_session session_id;
                             Log.H2_gateway.info "Session terminated: %s reason=client_delete \
                                profile=%s protocol_version=%s \
                                sse_active_before_stop=%b"
                               session_id
                               (Server_mcp_transport_http.profile_label profile)
                               protocol_version sse_active_before_stop;
                             let mcp_hdrs =
                               mcp_headers session_id protocol_version
                             in
                             h2_respond_empty h2_reqd ~extra_headers:mcp_hdrs))
                | None ->
                    h2_respond_text h2_reqd "Mcp-Session-Id required" ~status:`Bad_request ~extra_headers:cors))

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
      (* Both arms carry the same read gate the H1 route applies
         (server_routes_http_routes_frontend.ml wraps GET and POST /graphql in
         [with_read_auth]). /graphql is not in [is_public_read_path], so an
         unauthenticated caller must be rejected on either transport. *)
      | `GET, "/graphql" ->
          with_h2_read_auth h2_reqd (fun _state ->
            let nonce = fresh_graphql_csp_nonce () in
            let csp_header = ("content-security-policy", graphql_csp_header nonce) in
            h2_respond_html h2_reqd (graphql_playground_html ~nonce) ~extra_headers:(csp_header :: cors))

      | `POST, "/graphql" ->
          h2_read_body h2_reqd (fun body_str ->
            with_h2_read_auth h2_reqd (fun state ->
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

      (* H1 serves this through its route-local [with_public_read] wrapper
         (server_routes_http_routes_dashboard.ml). Keep H2 on the same public
         feature lane instead of letting the transport select a different
         access contract. *)
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

      (* Keep public dashboard read surfaces transport-neutral.  These all
         already have H1 handlers in [server_routes_http_routes_dashboard];
         an H2 client used to receive a 404 even though the Dashboard had
         deliberately made the corresponding request anonymous. *)
      | `GET, "/api/v1/dashboard/fusion-runs" ->
          with_h2_public_read h2_reqd (fun _state ->
            let runs = Fusion_run_registry.list_runs (Fusion_run_registry.global ()) in
            let json =
              `Assoc
                [ ("generated_at", `String (Masc_domain.now_iso ()))
                ; ("count", `Int (List.length runs))
                ; ("runs", `List (List.map Fusion_run_registry.run_to_yojson runs))
                ]
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/verification-runs" ->
          with_h2_public_read h2_reqd (fun _state ->
            let runs =
              Verification_run_registry.list_runs (Verification_run_registry.global ())
            in
            let json =
              `Assoc
                [ ("generated_at", `String (Masc_domain.now_iso ()))
                ; ("count", `Int (List.length runs))
                ; ( "runs"
                  , `List (List.map Verification_run_registry.run_to_yojson runs) )
                ]
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/exact-lane-runs" ->
          with_h2_public_read h2_reqd (fun _state ->
            let runs =
              Exact_lane_run_registry.list_runs (Exact_lane_run_registry.global ())
            in
            let json =
              `Assoc
                [ ("generated_at", `String (Masc_domain.now_iso ()))
                ; ("count", `Int (List.length runs))
                ; ("runs", `List (List.map Exact_lane_run_registry.run_to_yojson runs))
                ]
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/runtime-defaults" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              Server_dashboard_runtime_defaults_json.current
                ~generated_at_iso:(Masc_domain.now_iso ()) ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/runtime-probe" ->
          with_h2_public_read h2_reqd (fun _state ->
            let force =
              Server_utils.bool_query_param httpun_request "force" ~default:false
            in
            let json = dashboard_runtime_probe_http_json ~force () in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/runtime/resolved" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Server_dashboard_runtime_resolved_json.build
                ~generated_at_iso:(Masc_domain.now_iso ())
                ~config:(Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET,
        ( "/api/v1/providers"
        | "/api/v1/models/metrics"
        | "/api/v1/dashboard/keeper-costs"
        | "/api/v1/dashboard/cost-latency"
        | "/api/v1/dashboard/keeper-decisions"
        | "/api/v1/dashboard/keeper-decisions-log" ) ->
          with_h2_public_read h2_reqd (fun state ->
            match
              Server_routes_http_routes_provider_runs.public_read_json
                ~sw ~state httpun_request
            with
            | Some json -> h2_respond_json_value h2_reqd json ~extra_headers:cors
            | None ->
              h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
                ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/cache-stats" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd (Dashboard_cache.stats ())
              ~extra_headers:cors)

      | `GET, "/api/v1/gate/status" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json = Server_routes_http_routes_channel_gate.gate_status_json () in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/gate/connectors" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              Server_routes_http_routes_channel_gate.gate_connectors_json
                httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/audit" ->
          with_h2_public_read h2_reqd (fun state ->
            let limit =
              Server_utils.int_query_param httpun_request "limit" ~default:100
              |> Server_utils.clamp ~min_v:1 ~max_v:500
            in
            let actor_filter = Server_utils.query_param httpun_request "actor" in
            let kind_filter = Server_utils.query_param httpun_request "kind" in
            let severity_filter = Server_utils.query_param httpun_request "severity" in
            let float_filter key =
              match Server_utils.query_param httpun_request key with
              | Some raw -> float_of_string_opt (String.trim raw)
              | None -> None
            in
            let since_filter = float_filter "since" in
            let until_filter = float_filter "until" in
            let fetch_limit =
              match actor_filter, kind_filter, severity_filter with
              | None, None, None -> limit
              | _ -> min 5000 (limit * 20)
            in
            let entries =
              Audit_log.read_entries ~n:fetch_limit (Mcp_server.workspace_config state)
            in
            let json =
              Audit_log.audit_events_response_json ?actor:actor_filter
                ?kind:kind_filter ?severity:severity_filter ?since:since_filter
                ?until:until_filter ~limit entries
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/prompts" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd (Prompt_registry.prompts_json ())
              ~extra_headers:cors)

      | `GET, path
        when String.equal path "/api/v1/repositories"
             || String.starts_with ~prefix:"/api/v1/repositories/" path ->
          with_h2_public_read h2_reqd (fun state ->
            let status, json =
              Server_routes_http_routes_repositories.public_get_response
                state httpun_request
            in
            h2_respond_json_value h2_reqd json
              ~status:(status :> H2.Status.t) ~extra_headers:cors)

      | `GET,
        ( "/api/v1/workspace/tree"
        | "/api/v1/workspace/children"
        | "/api/v1/workspace/file"
        | "/api/v1/git/blame"
        | "/api/v1/git/diff" ) ->
          with_h2_public_read h2_reqd (fun state ->
            match
              Server_routes_http_routes_workspace.workspace_public_read_response
                ~state httpun_request
            with
            | Some response ->
              h2_respond_json_value h2_reqd response.body
                ~status:(response.status :> H2.Status.t)
                ~extra_headers:(response.extra_headers @ cors)
            | None ->
              h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
                ~extra_headers:cors)

      | `GET, path when String.starts_with ~prefix:"/api/v1/keepers/" path ->
          let dispatch_keeper_get state =
            match Keeper_chat_operations.get_route path with
            | Some route ->
              let response =
                Keeper_chat_operations.get_response_for_route
                  state httpun_request route
              in
              h2_respond_json_value h2_reqd response.body
                ~status:(response.status :> H2.Status.t) ~extra_headers:cors
            | None ->
              (match Keeper_event_queue_operator.pending_get_route path with
               | Some keeper_name ->
                 let response =
                   Keeper_event_queue_operator.pending_response_for_request
                     state httpun_request ~keeper_name
                 in
                 h2_respond_json_value h2_reqd response.body
                   ~status:(response.status :> H2.Status.t) ~extra_headers:cors
               | None ->
                 (match
                    Server_dashboard_http_keeper_api.public_get_response_for_request
                      state httpun_request
                  with
                  | Some response ->
                    h2_respond_json_value h2_reqd response.body
                      ~status:(response.status :> H2.Status.t) ~extra_headers:cors
                  | None ->
                    h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
                      ~extra_headers:cors))
          in
          (match Server_dashboard_http_keeper_api.keeper_get_permission path with
           | Some permission ->
             with_h2_keeper_get_auth h2_reqd ~permission
               (fun state _agent_name -> dispatch_keeper_get state)
           | None ->
             with_h2_public_read h2_reqd dispatch_keeper_get)

      | `GET, "/api/v1/dashboard/logs" ->
          with_h2_public_read h2_reqd (fun state ->
            let limit =
              Server_utils.int_query_param httpun_request "limit" ~default:200
              |> max 1 |> min 3000
            in
            let level_filter =
              match Server_utils.query_param httpun_request "level" with
              | Some value -> value
              | None -> "DEBUG"
            in
            match Log.level_of_string_opt level_filter with
            | None ->
              h2_respond_json_value
                h2_reqd
                (`Assoc
                   [ ("error", `String "invalid_log_level")
                   ; ( "message"
                     , `String
                         "level must be one of debug, info, warn, warning, error" )
                   ; ("level", `String level_filter)
                   ])
                ~status:`Bad_request ~extra_headers:cors
            | Some applied_level ->
              let min_level = Log.level_to_int applied_level in
              let sequence_param key =
                match Server_utils.query_param httpun_request key with
                | None -> None
                | Some _ ->
                  let value =
                    Server_utils.int_query_param httpun_request key ~default:(-1)
                  in
                  if value < 0 then None else Some value
              in
              let since_seq = sequence_param "since_seq" in
              let before_seq = sequence_param "before_seq" in
              let module_filter =
                match Server_utils.query_param httpun_request "module" with
                | Some value -> value
                | None -> ""
              in
              let category_filter =
                Server_utils.query_param httpun_request "category"
              in
              let exclude_category =
                match Server_utils.query_param httpun_request "exclude_category" with
                | None -> None
                | Some raw ->
                  let categories =
                    raw
                    |> String.split_on_char ','
                    |> List.map String.trim
                    |> List.filter (fun value -> value <> "")
                  in
                  (match categories with
                   | [] -> None
                   | _ :: _ -> Some categories)
              in
              let entries =
                Log.Ring.recent ~limit ~min_level ~module_filter ?since_seq
                  ?before_seq ?category_filter ?exclude_category ()
              in
              let json =
                Server_routes_http_routes_dashboard_setup.dashboard_logs_json
                  ~config:(Mcp_server.workspace_config state) ~limit ~level_filter
                  ~applied_level ~min_level ~module_filter ~since_seq ~before_seq
                  ~category_filter ~exclude_category entries
              in
              h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/provider-logs" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              Server_routes_http_dashboard_provider_logs.dashboard_provider_logs_json ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/provider-logs/tail" ->
          with_h2_public_read h2_reqd (fun _state ->
            let status, json =
              Server_routes_http_dashboard_provider_logs.dashboard_provider_log_tail_json
                httpun_request
            in
            h2_respond_json_value h2_reqd json
              ~status:(status :> H2.Status.t) ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/keeper-memory-health" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Server_dashboard_http_keeper_memory_health.keeper_memory_health_http_json
                ~base_path:(Mcp_server.workspace_config state).base_path
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/gate/tool-events" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_gate_tool_events_http_json httpun_request
                ~base_path:(Mcp_server.workspace_config state).base_path
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/operator" ->
          with_h2_public_read h2_reqd (fun state ->
            let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/operator/digest" ->
          with_h2_public_read h2_reqd (fun state ->
            match operator_digest_http_json ~state ~sw ~clock httpun_request with
            | Ok json -> h2_respond_json_value h2_reqd json ~extra_headers:cors
            | Error message ->
              h2_respond_json_value h2_reqd (operator_error_json message)
                ~status:`Bad_request ~extra_headers:cors)

      (* Same owner and same shape as the HTTP/1 route; a client that reaches
         the server over H2 must not see a different projection. *)
      | `GET, "/api/v1/dashboard/scheduled-automation" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Domain_pool_ref.submit_io_or_inline (fun () ->
                Server_dashboard_schedule_projection
                .scheduled_automation_dashboard_json
                  (Mcp_server.workspace_config state))
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      (* The tool inventory had no H2 route at all: an H2 client got 404 where
         an HTTP/1 client got the inventory. Same selector as the HTTP/1 route,
         so the snapshot fast path and the per-actor fallback both apply. *)
      | `GET, "/api/v1/dashboard/tools" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Server_dashboard_snapshot_select.select_tools_json
                ?actor:
                  (dashboard_actor_for_request
                     ~base_path:(Mcp_server.workspace_config state).base_path
                     httpun_request)
                (Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

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

      | `GET, "/api/v1/dashboard/gate" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_gate_http_json httpun_request
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

      | `GET, "/api/v1/dashboard/tool-quality" ->
          with_h2_public_read h2_reqd (fun _state ->
            let n =
              match Server_utils.query_param httpun_request "n" with
              | Some raw ->
                (match int_of_string_opt raw with
                 | Some value -> max 1 (min 50000 value)
                 | None -> 5000)
              | None -> 5000
            in
            let window_hours =
              match Server_utils.query_param httpun_request "window_hours" with
              | Some raw ->
                (match float_of_string_opt raw with
                 | Some value -> Some (max 0.1 (min 168.0 value))
                 | None -> None)
              | None -> None
            in
            let json = Dashboard_http_tool_quality.aggregate ~n ?window_hours () in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/keeper-feature-proof" ->
          with_h2_public_read h2_reqd (fun state ->
            let window_hours =
              match Server_utils.query_param httpun_request "window_hours" with
              | Some raw ->
                (match float_of_string_opt raw with
                 | Some value when Float.is_finite value ->
                   Some (max 0.1 (min 168.0 value))
                 | Some _ | None -> None)
              | None -> None
            in
            let json =
              Dashboard_keeper_feature_proof.json
                ~config:(Mcp_server.workspace_config state) ?window_hours ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/harness-health" ->
          with_h2_public_read h2_reqd (fun state ->
            let since = Server_utils.query_param httpun_request "since" in
            let until = Server_utils.query_param httpun_request "until" in
            let json =
              Dashboard_harness_health.json
                ~config:(Mcp_server.workspace_config state) ?since ?until ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/feature-health" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd (Dashboard_feature_health.json ())
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/eval-feed" ->
          with_h2_public_read h2_reqd (fun state ->
            let base_path = (Mcp_server.workspace_config state).base_path in
            let agent_name = Server_utils.query_param httpun_request "agent_name" in
            let limit =
              Server_utils.int_query_param httpun_request "limit" ~default:10
              |> max 1 |> min 100
            in
            let json =
              match agent_name with
              | Some name when String.trim name <> "" ->
                let name = String.trim name in
                let snapshots =
                  Dashboard_eval_feed.read_latest ~base_path ~agent_name:name ~limit
                in
                `Assoc
                  [ ("generated_at", `String (Masc_domain.now_iso ()))
                  ; ("agent_name", `String name)
                  ; ("count", `Int (List.length snapshots))
                  ; ( "snapshots"
                    , `List (List.map Dashboard_eval_feed.snapshot_to_json snapshots) )
                  ]
              | Some _ | None ->
                let agents = Dashboard_eval_feed.list_agents ~base_path in
                let agent_rows =
                  List.map
                    (fun name ->
                       let latest =
                         match
                           Dashboard_eval_feed.read_latest
                             ~base_path ~agent_name:name ~limit:1
                         with
                         | snapshot :: _ -> Dashboard_eval_feed.snapshot_to_json snapshot
                         | [] -> `Null
                       in
                       `Assoc [ ("agent_name", `String name); ("latest", latest) ])
                    agents
                in
                `Assoc
                  [ ("generated_at", `String (Masc_domain.now_iso ()))
                  ; ("agent_count", `Int (List.length agents))
                  ; ("agents", `List agent_rows)
                  ]
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/telemetry" ->
          with_h2_public_read h2_reqd (fun state ->
            let json, timing_headers =
              Server_routes_http_routes_dashboard_setup
              .dashboard_telemetry_projection ~state httpun_request
            in
            h2_respond_json_value h2_reqd json
              ~extra_headers:(timing_headers @ cors))

      | `GET, "/api/v1/dashboard/telemetry/summary" ->
          with_h2_public_read h2_reqd (fun state ->
            let timing = Server_timing.create () in
            let json =
              Server_dashboard_snapshot_select.select_telemetry_summary_json
                ~timing (Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json
              ~extra_headers:(Server_timing.extra_header timing @ cors))

      | `GET, "/api/v1/agent-activity" ->
          with_h2_public_read h2_reqd (fun state ->
            match
              Server_dashboard_http_agent_api.positive_float_param
                ~name:"hours" ~default:24.0
                (Server_utils.query_param httpun_request "hours")
            with
            | Error detail ->
              h2_respond_json_value h2_reqd (`Assoc [ ("error", `String detail) ])
                ~status:`Bad_request ~extra_headers:cors
            | Ok hours ->
              let since = Time_compat.now () -. (hours *. Masc_time_constants.hour) in
              let activities =
                Telemetry_eio.summarize_agent_activity
                  (Mcp_server.workspace_config state) ~since
              in
              let json =
                `Assoc
                  [ ("hours", `Float hours)
                  ; ( "agents"
                    , `List
                        (List.map
                           (fun (activity : Telemetry_eio.agent_activity) ->
                              `Assoc
                                [ ("agent_id", `String activity.agent_id)
                                ; ("tool_calls", `Int activity.tool_calls)
                                ; ("success_count", `Int activity.success_count)
                                ; ("failure_count", `Int activity.failure_count)
                                ; ("first_seen", `Float activity.first_seen)
                                ; ("last_seen", `Float activity.last_seen)
                                ])
                           activities) )
                  ]
              in
              h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/tool-metrics" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              Tool_unified.summary_report
                ~runtime_metrics:Runtime_observation.runtime_metrics_json ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/agent-timeline" ->
          with_h2_public_read h2_reqd (fun state ->
            let agent_name =
              match Server_utils.query_param httpun_request "agent_name" with
              | Some name -> String.trim name
              | None -> ""
            in
            if agent_name = "" then
              h2_respond_json_value
                h2_reqd
                (`Assoc
                   [ ("error", `String "agent_name query parameter is required") ])
                ~status:`Bad_request ~extra_headers:cors
            else
              let params =
                let ( let* ) = Result.bind in
                let* since_hours =
                  Server_dashboard_http_agent_api.positive_float_param
                    ~name:"since_hours" ~default:4.0
                    (Server_utils.query_param httpun_request "since_hours")
                in
                let* limit =
                  Server_dashboard_http_agent_api.positive_int_param
                    ~name:"limit" ~default:20
                    (Server_utils.query_param httpun_request "limit")
                in
                Ok (since_hours, limit)
              in
              (match params with
               | Error detail ->
                 h2_respond_json_value h2_reqd
                   (`Assoc [ ("error", `String detail) ])
                   ~status:`Bad_request ~extra_headers:cors
               | Ok (since_hours, limit) ->
                 let config = Mcp_server.workspace_config state in
                 let json =
                   Tool_agent_timeline.build_timeline
                     ~load_chat:(fun ~agent_name ->
                       Keeper_chat_timeline_source.lines_for
                         ~base_dir:config.base_path ~keeper_name:agent_name)
                     config ~agent_name ~since_hours ~limit ~include_tasks:true
                     ~include_board:false ~include_tool_calls:true
                 in
                 h2_respond_json_value h2_reqd json ~extra_headers:cors))

      | `GET, "/api/v1/agent-relations" ->
          with_h2_public_read h2_reqd (fun _state ->
            let agent_name =
              match Server_utils.query_param httpun_request "agent_name" with
              | Some name -> String.trim name
              | None -> ""
            in
            if agent_name = "" then
              h2_respond_json_value
                h2_reqd
                (`Assoc
                   [ ("error", `String "agent_name query parameter is required") ])
                ~status:`Bad_request ~extra_headers:cors
            else
              h2_respond_json_value h2_reqd
                (Dashboard_agent_relations.json ~agent_name ()) ~extra_headers:cors)

      | `GET, "/api/v1/attribution/recent" ->
          with_h2_public_read h2_reqd (fun _state ->
            let gate =
              Server_routes_http_routes_attribution.trimmed_query_param
                httpun_request "gate"
            in
            let limit =
              match
                Server_routes_http_routes_attribution.trimmed_query_param
                  httpun_request "limit"
              with
              | Some raw -> int_of_string_opt raw
              | None -> None
            in
            let json =
              Server_routes_http_routes_attribution.recent_json ?gate ?limit ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/attribution/summary" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json = Server_routes_http_routes_attribution.summary_json () in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/verification/requests" ->
          with_h2_public_read h2_reqd (fun state ->
            let task_id =
              match Server_utils.query_param httpun_request "task_id" with
              | Some raw ->
                let value = String.trim raw in
                if value = "" then None else Some value
              | None -> None
            in
            let limit =
              match Server_utils.query_param httpun_request "limit" with
              | Some raw ->
                let value = String.trim raw in
                if value = "" then None else int_of_string_opt value
              | None -> None
            in
            let json =
              Dashboard_verification.requests_json
                ~base_path:(Mcp_server.workspace_config state).base_path
                ?task_id ?limit ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/verification/summary" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Dashboard_verification.summary_json
                ~base_path:(Mcp_server.workspace_config state).base_path ()
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/verification/specs" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd (Dashboard_tla_specs.specs_json ())
              ~extra_headers:cors)

      | `GET, "/api/v1/verification/tlc-results" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value h2_reqd (Dashboard_tla_specs.tlc_results_json ())
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/agent_core/telemetry/recent" ->
          with_h2_public_read h2_reqd (fun _state ->
            let provider = agent_core_telemetry_provider_param httpun_request in
            let limit = agent_core_telemetry_limit_param httpun_request in
            let json = Dashboard_agent_core_bridge.recent_json ?provider ~limit () in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/agent_core/telemetry/summary" ->
          with_h2_public_read h2_reqd (fun _state ->
            let provider = agent_core_telemetry_provider_param httpun_request in
            let limit = agent_core_telemetry_limit_param httpun_request in
            let json = Dashboard_agent_core_bridge.summary_json ?provider ~limit () in
            h2_respond_json_value h2_reqd json
              ~extra_headers:cors)

      (* IDE writes use the same public feature projection as HTTP/1.  The
         body adapter is transport-specific, but no selected repository or
         bearer is required to create/delete an annotation or publish a
         cursor. *)
      | `POST, "/api/v1/ide/annotations" ->
          with_h2_public_read h2_reqd (fun state ->
            h2_read_body h2_reqd (fun body ->
              h2_respond_ide_public_mutation
                (Server_ide_http.public_annotation_create_response
                   ~state
                   ~request:httpun_request
                   ~body)))

      | `DELETE, path
        when String.starts_with ~prefix:"/api/v1/ide/annotations/" path ->
          with_h2_public_read h2_reqd (fun state ->
            h2_respond_ide_public_mutation
              (Server_ide_http.public_annotation_delete_response
                 ~state
                 ~request:httpun_request))

      | `POST, "/api/v1/ide/cursors" ->
          with_h2_public_read h2_reqd (fun state ->
            h2_read_body h2_reqd (fun body ->
              h2_respond_ide_public_mutation
                (Server_ide_http.public_cursor_create_response
                   ~state
                   ~request:httpun_request
                   ~body)))

      (* The snapshot is process-local observation state, so it remains useful
         during boot before [Mcp_server.server_state] exists.  H1 has the same
         startup behavior; do not wrap this route in [with_h2_public_read]. *)
      | `GET, "/api/v1/ide/observations/snapshot" ->
          h2_respond_ide_public_read
            (Server_ide_http.observation_snapshot_public_read_response
               httpun_request)

      (* Route-local public IDE reads use the same projection as H1. Public
         POST/DELETE handlers above own the body-bearing half of this feature
         lane. *)
      | `GET,
        ( "/api/v1/agents"
        | "/api/v1/status"
        | "/api/v1/ide/annotations"
        | "/api/v1/ide/regions"
        | "/api/v1/ide/events"
        | "/api/v1/ide/presence"
        | "/api/v1/ide/cursors"
        | "/api/v1/ide/memory" ) ->
          with_h2_public_read h2_reqd (fun state ->
            match Server_ide_http.public_read_response ~state httpun_request with
            | Some response -> h2_respond_ide_public_read response
            | None ->
              h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
                ~extra_headers:cors)

      | `GET, "/api/v1/openapi.json" ->
          let resolved_host = Server_request_authority.host request_authority in
          let resolved_port =
            Option.value
              ~default:(Env_config_core.masc_http_port_int ())
              (Server_request_authority.port request_authority)
          in
          let json =
            Transport.Rest.generate_openapi_document
              ~host:resolved_host ~port:resolved_port ()
          in
          h2_respond_json_value h2_reqd json ~extra_headers:cors

      | `GET, "/api/v1/namespace/current"
      | `GET, "/api/v1/workspace/current"
      | `POST, "/api/v1/namespace/current"
      | `POST, "/api/v1/workspace/current" ->
          h2_respond_removed_surface h2_reqd ~surface:"namespace" ~extra_headers:cors

      | `GET, "/api/v1/board/reactions/catalog" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value
              h2_reqd
              (Server_board_reaction_http.catalog_json ())
              ~extra_headers:cors)

      | `GET, "/api/v1/board/reactions" ->
          with_h2_token_permission_auth
            h2_reqd
            ~permission:Masc_domain.CanReadState
            (fun _state actor ->
               let actor = Server_utils.board_actor_author_for_write actor in
               let result =
                 Result.bind
                   (Server_board_reaction_http.target_of_strings
                      ~target_type:
                        (Server_utils.query_param httpun_request "target_type")
                      ~target_id:
                        (Server_utils.query_param httpun_request "target_id"))
                   (Server_board_reaction_http.list_json ~actor)
               in
               h2_respond_board_reaction_result h2_reqd result)

      | `POST, "/api/v1/board/reactions" ->
          with_h2_token_permission_auth
            h2_reqd
            ~permission:Masc_domain.CanVote
            (fun _state actor ->
               let actor = Server_utils.board_actor_author_for_write actor in
               h2_read_body h2_reqd (fun body ->
                 let parsed =
                   match Yojson.Safe.from_string body with
                   | json -> Server_board_reaction_http.toggle_request_of_json json
                   | exception Yojson.Json_error message ->
                     Error (Server_board_reaction_http.malformed_json message)
                 in
                 let result =
                   Result.bind
                     parsed
                     (Server_board_reaction_http.toggle_json ~actor)
                 in
                 h2_respond_board_reaction_result h2_reqd result))

      (* ═══════════════════════════════════════════════════════════════════════
         Delegated route groups
         ═══════════════════════════════════════════════════════════════════════ *)
      | _
        when Server_h2_gateway_routes_extra.dispatch ~h2_reqd ~httpun_request
               ~cors ~path
               ~config:
                 (Option.map
                    (fun state -> (Mcp_server.workspace_config state))
                    (current_server_state ()))
               httpun_meth ->
          ()

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    if
      is_mcp_transport_request httpun_request
      && not (validate_origin ~request_authority httpun_request)
    then
      h2_respond_json_value
        h2_reqd
        (`Assoc
           [ "jsonrpc", `String "2.0"
           ; ( "error"
             , `Assoc
                 [ ( "code"
                   , `Int
                       (Mcp_error_code.to_wire_code
                          Mcp_error_code.Invalid_request) )
                 ; "message", `String "Invalid origin"
                 ] )
           ; "id", `Null
           ])
        ~status:`Forbidden
        ~extra_headers:cors
    else
      try dispatch_h2_route () with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Auth.Auth_config_error _ ->
        h2_respond_text
          h2_reqd
          "Authentication configuration unavailable"
          ~status:`Service_unavailable
          ~extra_headers:cors
      | exn ->
        let msg = Printexc.to_string exn in
        Log.Http.error "Handler error: %s" msg;
        h2_respond_text
          h2_reqd
          ("500 Internal Server Error: " ^ msg)
          ~status:`Internal_server_error
          ~extra_headers:cors
    in
    match
      Server_request_authority.classify_h2_request ~trust_policy h2_req
    with
    | Server_request_authority.H2_authority
        (Server_request_authority.Single request_authority) ->
      (match classify_request_origin ~request_authority httpun_request with
       | Multiple_origins ->
         h2_request_authority_bad_request
           ~error_code:"request_origin_multiple"
           ~message:"request contains more than one Origin field"
           h2_reqd
       | Malformed_origin ->
         h2_request_authority_bad_request
           ~error_code:"request_origin_malformed"
           ~message:"request Origin is not one complete HTTP(S) serialized origin"
           h2_reqd
       | Missing_origin | Single_origin _ ->
         Server_request_authority.with_current request_authority (fun () ->
           handle_admitted_request request_authority))
    | Server_request_authority.H2_authority Server_request_authority.Missing ->
      h2_request_authority_bad_request
        ~error_code:"request_authority_missing"
        ~message:"request is missing :authority"
        h2_reqd
    | Server_request_authority.H2_authority Server_request_authority.Multiple ->
      h2_request_authority_bad_request
        ~error_code:"request_authority_multiple"
        ~message:"request contains multiple authority fields"
        h2_reqd
    | Server_request_authority.H2_authority Server_request_authority.Malformed ->
      h2_request_authority_bad_request
        ~error_code:"request_authority_malformed"
        ~message:"request authority is malformed"
        h2_reqd
    | Server_request_authority.H2_authority Server_request_authority.Untrusted ->
      h2_request_authority_bad_request
        ~error_code:"request_authority_untrusted"
        ~message:"request authority is not a configured server identity"
        h2_reqd
    | Server_request_authority.Unsupported_asterisk_form_options ->
      h2_request_authority_bad_request
        ~error_code:"request_target_asterisk_unsupported"
        ~message:"MASC does not support authority-free OPTIONS *"
        h2_reqd
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
