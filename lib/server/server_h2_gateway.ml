
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
  (* subscriptions/listen over h2c. The HTTP/1 side parks on the SSE
   connection's stop promise; there is no such record here, so this keeps its
   own: a write that fails means the peer is gone, and a keepalive comment is
   what makes a silent departure fail a write instead of never being noticed.

   The acknowledgement, the honoured filter, and the closure result come from
   [Mcp_subscriptions] rather than being rebuilt -- the two transports wrote
   their own header-mismatch body once and drifted. *)
let serve_subscriptions_listen_h2 ~sw ~clock ~cors ~body_str h2_reqd =
  match Server_mcp_transport_http.body_jsonrpc_id body_str with
  | None | Some `Null ->
    h2_respond_json h2_reqd
      (Mcp_error_code.jsonrpc_error_body Mcp_error_code.Invalid_request
         ~message:"subscriptions/listen requires a non-null request id")
      ~status:`Bad_request ~extra_headers:cors
  | Some subscription_id ->
    let headers =
      H2.Headers.of_list
        ([ ("content-type", "text/event-stream")
         ; ("cache-control", "no-cache")
         ; ("x-accel-buffering", "no")
         ]
         @ cors)
    in
    let writer =
      H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd
        (H2.Response.create ~headers `OK)
    in
    let stop, resolve_stop = Eio.Promise.create () in
    let closed = Atomic.make false in
    let stop_once () =
      if Atomic.compare_and_set closed false true then
        Eio.Promise.resolve resolve_stop ()
    in
    let write_frame text =
      if Atomic.get closed then false
      else
        try
          H2.Body.Writer.write_string writer text;
          H2.Body.Writer.flush writer (fun _ -> ());
          true
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | _ ->
          stop_once ();
          false
    in
    let send json =
      write_frame (Printf.sprintf "data: %s\n\n" (Yojson.Safe.to_string json))
    in
    let filter =
      Mcp_subscriptions.honoured_filter
        (Mcp_transport_protocol.subscription_filter_of_params
           (Server_mcp_transport_http.body_jsonrpc_params body_str))
    in
    if send (Mcp_subscriptions.acknowledgement ~subscription_id filter) then (
      let token = Mcp_subscriptions.register ~subscription_id ~filter ~send in
      Eio.Fiber.fork ~sw (fun () ->
        let rec beat () =
          if not (Atomic.get closed) then (
            Eio.Time.sleep clock 15.0;
            if write_frame ": keepalive\n\n" then beat ())
        in
        beat ());
      Eio.Promise.await stop;
      Mcp_subscriptions.unregister token;
      (* The stop signal fires on a failed write, so by the time this runs the
         peer is usually already gone and a closure that does not land is the
         ordinary case rather than an error. *)
      (* fire-and-forget: best effort on a stream that is already closing. *)
      ignore
        (send (Mcp_subscriptions.graceful_closure ~subscription_id) : bool));
    stop_once ();
    (* Cancellation travels as an exception in Eio, so a wildcard that ate it
       here would report a clean exit from a fiber the switch had cancelled. *)
    (try H2.Body.Writer.close writer with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> ())
  in

  (* The route match below admits exactly four MCP paths; classifying them
     here again must therefore never invent a profile for anything else. An
     unrouted path reaching this classifier is route-table drift, and a loud
     failure beats silently granting the widest (Full) surface (#8605
     family: unknown input never maps to a permissive default). *)
  let profile_for_mcp_path path =
    match path with
    | "/mcp/managed" -> Server_mcp_transport_http.Managed_agent
    | "/mcp/operator" -> Server_mcp_transport_http.Operator_remote
    | "/mcp" | "/" -> Server_mcp_transport_http.Full
    | unrouted ->
      invalid_arg ("mcp profile requested for unrouted path: " ^ unrouted)
  in

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
        (* One policy for both protocols (#28166). Same result as the [cors]
           computed above for this request; naming it here keeps H1 and H2
           reading the same function. *)
        ~extra_headers:
          (auth_error_headers
             ~status
             ~cors:(auth_error_cors_headers httpun_request))
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
        ~extra_headers:(Rate_limit.headers_agent_global ~key:rl_key @ cors);
      Transport_metrics.record_http_rate_limit_response
        ~acceptance:Transport_metrics.Accepted_by_writer
        ~protocol:Transport_metrics.H2
        ~scope:Transport_metrics.Agent
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
    (* H2 counterpart of [Server_auth.with_read_auth]: authorize on every
       request, with no [http_auth_strict_enabled] / [is_public_read_path]
       precondition. [with_h2_public_read] applies those preconditions and is
       therefore NOT interchangeable — a route the H1 side guards with
       [with_read_auth] must use this one, or the same path enforces different
       authorization depending on which transport the client negotiated. *)
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
      match Web_dashboard.load_dashboard_asset "index.html" with
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
          h2_respond_html
            h2_reqd
            "<html><body>Dashboard assets unavailable. Inspect /health dashboard_surface.recovery.</body></html>"
            ~status:`Service_unavailable
            ~extra_headers:cors
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
      | `POST, "/mcp"
      | `POST, "/"
      | `POST, "/mcp/managed"
      | `POST, "/mcp/operator" ->
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let profile = profile_for_mcp_path path in
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
                | Error rejection ->
                    let body =
                      Server_mcp_transport_http
                      .protocol_version_rejection_body rejection
                    in
                    h2_respond_json h2_reqd body ~status:`Bad_request
                      ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                | Ok () ->
                    (match auth_result with
                     | Error failure ->
                         Server_mcp_transport_http_respond
                         .record_mcp_auth_reject
                           ~endpoint:
                             ("h2 POST "
                             ^ Server_mcp_transport_http.profile_label profile)
                           ~claimed_agent:(agent_from_request httpun_request)
                           ~token_presented:(Option.is_some auth_token)
                           ~session_id:(Some session_id) failure;
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
                                 (Server_mcp_request_context.Header_mismatch rejection)
                               ->
                                 let body =
                                   Server_mcp_transport_http_headers.header_rejection_body body_str
                                     rejection
                                 in
                                 h2_respond_json h2_reqd body ~status:`Bad_request
                                   ~extra_headers:(cors @ mcp_headers session_id protocol_version)
                             | Ok post_context ->
                                 with_server_state h2_reqd (fun state ->
                                   let profile =
                                     mcp_eio_profile_of_transport_profile profile
                                   in
                                   if
                                     Server_mcp_transport_http
                                     .body_is_subscriptions_listen
                                       post_context.body_str
                                   then
                                     serve_subscriptions_listen_h2 ~sw ~clock
                                       ~cors ~body_str:post_context.body_str
                                       h2_reqd
                                   else
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

      | `DELETE, "/mcp"
      | `DELETE, "/mcp/managed"
      | `DELETE, "/mcp/operator" ->
          let profile = profile_for_mcp_path path in
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
               Server_mcp_transport_http_respond.record_mcp_auth_reject
                 ~endpoint:
                   ("h2 DELETE "
                   ^ Server_mcp_transport_http.profile_label profile)
                 ~claimed_agent:(agent_from_request httpun_request)
                 ~token_presented:
                   (Option.is_some (auth_token_from_request httpun_request))
                 ~session_id:session_id_opt failure;
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
                         | Error rejection ->
                             let body =
                               Server_mcp_transport_http
                               .protocol_version_rejection_body rejection
                             in
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

      | `GET, "/api/v1/dashboard/fusion-runs" ->
          with_h2_public_read h2_reqd (fun _state ->
            let json =
              Server_dashboard_fusion_run_projection.list_response
                ~generated_at:(Masc_domain.now_iso ())
                ~registry:(Fusion_run_registry.global ())
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, p
        when String.starts_with
               ~prefix:Server_dashboard_fusion_run_projection.detail_prefix
               p ->
          with_h2_public_read h2_reqd (fun _state ->
            let status, json =
              Server_dashboard_fusion_run_projection.detail_response
                ~generated_at:(Masc_domain.now_iso ())
                ~registry:(Fusion_run_registry.global ())
                ~path
            in
            h2_respond_json_value
              h2_reqd
              json
              ~status:(status :> H2.Status.t)
              ~extra_headers:cors)

      (* H1 serves this through [with_public_read]
         (server_routes_http_routes_dashboard.ml). [with_server_state] only
         fetches state; under MASC_HTTP_AUTH_STRICT it left the workspace
         timeline readable over h2c while H1 demanded a token. *)
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

      (* Same owner and same shape as the HTTP/1 route; a client that reaches
         the server over H2 must not see a different projection. *)
      | `GET, "/api/v1/dashboard/scheduled-automation" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              dashboard_scheduled_automation_query_http_json
                ~config:(Mcp_server.workspace_config state)
                httpun_request
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      (* The tool inventory had no H2 route at all: an H2 client got 404 where
         an HTTP/1 client got the inventory. Same selector as the HTTP/1 route,
         so the snapshot fast path and exact Keeper projection both apply. *)
      | `GET, "/api/v1/dashboard/tools" ->
          with_h2_public_read h2_reqd (fun state ->
            let json =
              Server_dashboard_snapshot_select.select_tools_json
                ?keeper:(Server_utils.query_param httpun_request "keeper")
                (Mcp_server.workspace_config state)
            in
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, "/api/v1/dashboard/skill-activations" ->
          with_h2_public_read h2_reqd (fun state ->
            match trimmed_query_param httpun_request "trace_id" with
            | None ->
              h2_respond_json_value h2_reqd
                (`Assoc [ "error", `String "trace_id query param is required" ])
                ~status:`Bad_request ~extra_headers:cors
            | Some raw_trace_id ->
              (match
                 Keeper_skill_activation_projection.resolve_trace_string
                   ~config:(Mcp_server.workspace_config state)
                   raw_trace_id
               with
               | Error detail ->
                 h2_respond_json_value h2_reqd
                   (`Assoc [ "error", `String detail ])
                   ~status:`Bad_request ~extra_headers:cors
               | Ok projection ->
                 let json =
                   Keeper_skill_activation_projection.trace_to_yojson projection
                 in
                 h2_respond_json_value h2_reqd json ~extra_headers:cors))

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

      (* H1 serves this through [with_public_read] (server_ide_http.ml:609). *)
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
          (* HTTP/1 wraps this in Server_auth.with_public_read and the path is
             not in the public-read allowlist, so strict mode answers 401
             there; this arm used to answer the document (#28161). *)
          with_h2_public_read h2_reqd (fun _state ->
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
            h2_respond_json_value h2_reqd json ~extra_headers:cors)

      | `GET, keeper_path
        when String.starts_with ~prefix:"/api/v1/keepers/" keeper_path
             && String.ends_with
                  ~suffix:
                    Server_dashboard_http_keeper_api_types.keeper_suffix_github_identity
                  keeper_path ->
          with_h2_token_permission_auth
            h2_reqd
            ~permission:Masc_domain.CanAdmin
            (fun state _actor ->
               let suffix =
                 Server_dashboard_http_keeper_api_types.keeper_suffix_github_identity
               in
               let keeper_name =
                 Server_dashboard_http_keeper_api_types.extract_keeper_name_for_suffix
                   keeper_path
                   suffix
               in
               let config = Mcp_server.workspace_config state in
               if String.equal keeper_name ""
               then
                 h2_respond_json_value
                   h2_reqd
                   (`Assoc [ "error", `String "missing or invalid keeper name" ])
                   ~status:`Bad_request
                   ~extra_headers:cors
               else if not (Keeper_config.validate_name keeper_name)
               then
                 h2_respond_json_value
                   h2_reqd
                   (`Assoc
                      [ "error"
                      , `String (Printf.sprintf "invalid keeper name: %s" keeper_name)
                      ])
                   ~status:`Bad_request
                   ~extra_headers:cors
               else
                 match Keeper_meta_store.read_meta config keeper_name with
                 | Error message ->
                   h2_respond_json_value
                     h2_reqd
                     (`Assoc [ "error", `String message ])
                     ~status:`Internal_server_error
                     ~extra_headers:cors
                 | Ok None ->
                   h2_respond_json_value
                     h2_reqd
                     (`Assoc
                        [ "error"
                        , `String (Printf.sprintf "keeper %S not found" keeper_name)
                        ])
                     ~status:`Not_found
                     ~extra_headers:cors
                 | Ok (Some _) ->
                   let hostname =
                     Option.value
                       ~default:"github.com"
                       (Server_utils.query_param httpun_request "hostname")
                   in
                   (match
                      Keeper_github_identity.observe
                        ~config
                        ~keeper_name
                        ~hostname
                    with
                    | Ok observation ->
                      h2_respond_json_value
                        h2_reqd
                        (Keeper_github_identity.observation_to_yojson observation)
                        ~extra_headers:cors
                    | Error message ->
                      h2_respond_json_value
                        h2_reqd
                        (`Assoc [ "error", `String message ])
                        ~status:`Bad_request
                        ~extra_headers:cors))

      | `POST, keeper_path
        when String.starts_with ~prefix:"/api/v1/keepers/" keeper_path
             && String.ends_with
                  ~suffix:
                    Server_dashboard_http_keeper_api_types.keeper_suffix_github_login
                  keeper_path ->
          with_h2_token_permission_auth
            h2_reqd
            ~permission:Masc_domain.CanAdmin
            (fun state _actor ->
               let suffix =
                 Server_dashboard_http_keeper_api_types.keeper_suffix_github_login
               in
               let keeper_name =
                 Server_dashboard_http_keeper_api_types.extract_keeper_name_for_suffix
                   keeper_path
                   suffix
               in
               let config = Mcp_server.workspace_config state in
               if String.equal keeper_name ""
               then
                 h2_respond_json_value
                   h2_reqd
                   (`Assoc [ "error", `String "missing or invalid keeper name" ])
                   ~status:`Bad_request
                   ~extra_headers:cors
               else if not (Keeper_config.validate_name keeper_name)
               then
                 h2_respond_json_value
                   h2_reqd
                   (`Assoc
                      [ "error"
                      , `String (Printf.sprintf "invalid keeper name: %s" keeper_name)
                      ])
                   ~status:`Bad_request
                   ~extra_headers:cors
               else
                 (* Effective meta, not persisted meta: [sandbox_profile] is
                    TOML-owned and a persisted read answers with the default,
                    which would send every Keeper's login to this host. *)
                 match Keeper_meta_store.read_effective_meta config keeper_name with
                 | Error message ->
                   h2_respond_json_value
                     h2_reqd
                     (`Assoc [ "error", `String message ])
                     ~status:`Internal_server_error
                     ~extra_headers:cors
                 | Ok None ->
                   h2_respond_json_value
                     h2_reqd
                     (`Assoc
                        [ "error"
                        , `String (Printf.sprintf "keeper %S not found" keeper_name)
                        ])
                     ~status:`Not_found
                     ~extra_headers:cors
                 | Ok (Some meta) ->
                   let hostname =
                     Option.value
                       ~default:"github.com"
                       (Server_utils.query_param httpun_request "hostname")
                   in
                   let headers =
                     H2.Headers.of_list
                       ([ "content-type", "text/event-stream"
                        ; "cache-control", "no-cache"
                        ; "x-accel-buffering", "no"
                        ]
                        @ cors)
                   in
                   let response = H2.Response.create ~headers `OK in
                   let writer =
                     H2.Reqd.respond_with_streaming
                       ~flush_headers_immediately:true
                       h2_reqd
                       response
                   in
                   let send_event event json =
                     H2.Body.Writer.write_string
                       writer
                       (Printf.sprintf
                          "event: %s\ndata: %s\n\n"
                          event
                          (Yojson.Safe.to_string json));
                     H2.Body.Writer.flush writer (fun _ -> ())
                   in
                   Fun.protect
                     ~finally:(fun () -> H2.Body.Writer.close writer)
                     (fun () ->
                        match
                          Keeper_github_identity.stream_login
                            ~config
                            ~keeper_name
                            (* Shaping a Remote_ssh lane runs commands on the
                               endpoint. Doing that before this response existed
                               left the browser waiting on a request that had not
                               answered at all. *)
                            ~make_lane:(fun () ->
                              Keeper_github_login_lane.for_keeper
                                ~config
                                ~meta
                                ~hostname)
                            ~is_closed:(fun () -> H2.Body.Writer.is_closed writer)
                            ~send_event
                        with
                        | Ok () -> ()
                        | Error message when not (H2.Body.Writer.is_closed writer) ->
                          send_event "error" (`Assoc [ "message", `String message ])
                        | Error _ -> ()))

      | `GET, "/api/v1/board/reactions/catalog" ->
          with_h2_public_read h2_reqd (fun _state ->
            h2_respond_json_value
              h2_reqd
              (Server_board_reaction_http.catalog_json ())
              ~extra_headers:cors)

      | `GET, "/api/v1/board/reactions/batch" ->
          with_h2_token_permission_auth
            h2_reqd
            ~permission:Masc_domain.CanReadState
            (fun _state actor ->
               let actor = Server_utils.board_actor_author_for_write actor in
               let result =
                 Server_board_reaction_http.targets_of_strings
                   ~target_type:
                     (Server_utils.query_param httpun_request "target_type")
                   ~target_ids:
                     (Server_utils.query_param httpun_request "target_ids")
                 |> Result.map (Server_board_reaction_http.list_batch_json ~actor)
               in
               h2_respond_board_reaction_result h2_reqd result)

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
               (* The delegated routes take this gateway's own public-read gate
                  rather than deciding for themselves; five of them answered
                  unauthenticated over h2c while HTTP/1 answered 401 (#28161). *)
               ~with_public_read:(fun f ->
                 with_h2_public_read h2_reqd (fun _state -> f ()))
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
