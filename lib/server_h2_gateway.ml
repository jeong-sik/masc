[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth
open Server_tts_proxy
open Server_trpg_rest
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

let make_request_handler ~sw ~clock ~server_start_time =
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
    let base_path =
      match !server_state with
      | Some s -> s.Mcp_server.room_config.base_path
      | None -> default_base_path ()
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
          h2_respond_html h2_reqd "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>" ~extra_headers:cors
    in

    let h2_authorize_tool state ~tool_name =
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
          let uptime_secs = int_of_float (Unix.gettimeofday () -. server_start_time) in
          let uptime_str =
            if uptime_secs < 60 then Printf.sprintf "%ds" uptime_secs
            else if uptime_secs < 3600 then Printf.sprintf "%dm %ds" (uptime_secs / 60) (uptime_secs mod 60)
            else Printf.sprintf "%dh %dm" (uptime_secs / 3600) ((uptime_secs mod 3600) / 60)
          in
          let state = get_server_state () in
          let build = Build_identity.current () in
          let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
          let social_runtime_json =
            Social_runtime.status_json ~config:state.Mcp_server.room_config
          in
          let gardener_json = Gardener.status_json () in
          let guardian_json = Guardian.status_json () in
          let sentinel_json = Sentinel.status_json () in
          let health_json = `Assoc [
            ("status", `String "ok");
            ("server", `String "masc-mcp");
            ("version", `String build.release_version);
            ("release_version", `String build.release_version);
            ("build", Build_identity.to_yojson build);
            ("protocol", `String "h2");
            ("uptime", `String uptime_str);
            ("sse_clients", `Int (Sse.client_count ()));
            ("lodge", lodge_json);
            ("social_runtime", social_runtime_json);
            ("gardener", gardener_json);
            ("guardian", guardian_json);
            ("sentinel", sentinel_json);
          ] in
          let body = Yojson.Safe.to_string health_json in
          h2_respond_json h2_reqd body ~extra_headers:cors

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
      | `POST, "/mcp" | `POST, "/" | `POST, "/mcp/managed" | `POST, "/mcp/operator" ->
          let session_id = match session_id_opt with
            | Some id -> id
            | None -> Mcp_session.generate ()
          in
          let auth_token = auth_token_from_request httpun_request in
          let protocol_version = get_protocol_version_for_session ~session_id httpun_request in
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else if String.equal path "/mcp/managed" then Mcp_eio.Managed_agent
            else Mcp_eio.Full
          in
          (* HTTP-level auth check for MCP endpoints *)
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ ->
                verify_mcp_auth ~base_path httpun_request
            | Mcp_eio.Operator_remote ->
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
                         let body = Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg in
                         h2_respond_json h2_reqd body ~status:`Unauthorized ~extra_headers:(("www-authenticate", "Bearer") :: cors)
                     | Ok _cred_opt ->
                         h2_read_body h2_reqd (fun body_str ->
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
                                 let state = get_server_state ()
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
                                     h2_respond_json h2_reqd body ~extra_headers:mcp_hdrs))))

      | `DELETE, "/mcp" | `DELETE, "/mcp/managed" | `DELETE, "/mcp/operator" ->
          let profile =
            if String.equal path "/mcp/operator" then Mcp_eio.Operator_remote
            else if String.equal path "/mcp/managed" then Mcp_eio.Managed_agent
            else Mcp_eio.Full
          in
          let base_path = match !server_state with
            | Some s -> s.Mcp_server.room_config.base_path
            | None -> default_base_path ()
          in
          let auth_result =
            match profile with
            | Mcp_eio.Full | Mcp_eio.Managed_agent | Mcp_eio.Role_filtered _ -> Ok None
            | Mcp_eio.Operator_remote ->
                verify_operator_mcp_auth ~base_path httpun_request
          in
          (match auth_result with
           | Error msg ->
               let body =
                 Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32001,"message":"%s"}}|} msg
               in
               h2_respond_json h2_reqd body ~status:`Unauthorized
                 ~extra_headers:(("www-authenticate", "Bearer") :: cors)
           | Ok _ ->
               (match session_id_opt with
                | Some session_id -> (
                    match validate_mcp_session_delete_profile ~profile session_id with
                    | Error msg ->
                        let body =
                          Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32600,"message":"%s"}}|} msg
                        in
                        h2_respond_json h2_reqd body ~status:`Conflict
                          ~extra_headers:cors
                    | Ok () ->
                        (match Server_mcp_transport_http.validate_protocol_version_continuity
                                 ~session_id httpun_request with
                         | Error msg ->
                             let body =
                               Printf.sprintf {|{"jsonrpc":"2.0","error":{"code":-32600,"message":"%s"}}|} msg
                             in
                             h2_respond_json h2_reqd body ~status:`Bad_request
                               ~extra_headers:(cors @ mcp_headers session_id (get_protocol_version httpun_request))
                         | Ok () ->
                             stop_sse_session session_id;
                             Sse.unregister session_id;
                             forget_mcp_session session_id;
                             Printf.printf "🔚 Session terminated: %s\n%!" session_id;
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

      | `GET, "/dashboard/lodge" ->
          let etag_value = "\"" ^ Lodge_dashboard.etag () ^ "\"" in
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
               let body = Lodge_dashboard.html () in
               let extra = [("etag", etag_value); ("cache-control", dashboard_index_cache_control)] @ cors in
               h2_respond_html h2_reqd body ~extra_headers:extra)

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
            let state = get_server_state ()
            in
            let response = Graphql_api.handle_request ~config:state.room_config body_str in
            let status = match response.status with `OK -> `OK | `Bad_request -> `Bad_request in
            h2_respond_json h2_reqd response.body ~status ~extra_headers:cors
          )

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
          let state = get_server_state () in
          let json = dashboard_shell_http_json state.Mcp_server.room_config in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/room-truth" ->
          let state = get_server_state () in
          let json =
            dashboard_room_truth_http_json ~state ~sw ~clock httpun_request
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/execution" ->
          let state = get_server_state () in
          let json = dashboard_execution_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/memory" ->
          let json = dashboard_memory_http_json httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/governance" ->
          let state = get_server_state () in
          let json =
            dashboard_governance_http_json httpun_request
              ~base_path:state.Mcp_server.room_config.base_path
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/planning" ->
          let state = get_server_state () in
          let json =
            dashboard_planning_http_json httpun_request
              ~config:state.Mcp_server.room_config
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/semantics" ->
          let json = dashboard_semantics_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/mission" ->
          let state = get_server_state () in
          let json = dashboard_mission_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/session" ->
          let state = get_server_state () in
          let json = dashboard_session_http_json ~state ~sw ~clock httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/mission/briefing" ->
          let state = get_server_state () in
          let json =
            dashboard_mission_briefing_http_json ~state ~sw ~clock
              httpun_request
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/dashboard/proof" ->
          let state = get_server_state () in
          let json = dashboard_proof_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/mdal/loops" ->
          let state = get_server_state () in
          (match mdal_loops_json ~config:state.Mcp_server.room_config httpun_request with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error msg ->
              h2_respond_json h2_reqd
                (Yojson.Safe.to_string (mdal_loops_error_json msg))
                ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane" ->
          let state = get_server_state () in
          let json = command_plane_snapshot_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/summary" ->
          let state = get_server_state () in
          let json = command_plane_summary_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/help" ->
          let json = command_plane_help_http_json () in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/topology" ->
          let state = get_server_state () in
          let json = command_plane_topology_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          let json = command_plane_units_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          let json = command_plane_operations_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachments" ->
          let state = get_server_state () in
          let json = command_plane_detachments_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/detachment-status" ->
          let state = get_server_state () in
          (match command_plane_detachment_status_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:`Bad_request ~extra_headers:cors)

      | `GET, "/api/v1/command-plane/decisions" ->
          let state = get_server_state () in
          let json = command_plane_decisions_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/capacity" ->
          let state = get_server_state () in
          let json = command_plane_capacity_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/alerts" ->
          let state = get_server_state () in
          let json = command_plane_alerts_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/traces" ->
          let state = get_server_state () in
          let json = command_plane_traces_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/swarm" ->
          let state = get_server_state () in
          let json = command_plane_swarm_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/command-plane/orchestra" ->
          let state = get_server_state () in
          let json = command_plane_orchestra_http_json ~state httpun_request in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/chains/summary" ->
          let state = get_server_state () in
          (match command_plane_chain_summary_http_json ~state httpun_request with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)

      | `GET, "/api/v1/chains/events" ->
          command_plane_chain_events_h2 ~request:httpun_request h2_reqd

      | `GET, path when String.length path > String.length "/api/v1/chains/runs/"
                        && String.sub path 0 (String.length "/api/v1/chains/runs/")
                           = "/api/v1/chains/runs/" ->
          let state = get_server_state () in
          let prefix_len = String.length "/api/v1/chains/runs/" in
          let run_id =
            String.sub path prefix_len (String.length path - prefix_len)
          in
          (match command_plane_chain_run_http_json ~state httpun_request run_id with
           | Ok json ->
               h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                 ~extra_headers:cors
           | Error message ->
               h2_respond_json h2_reqd
                 (Yojson.Safe.to_string (command_plane_error_json message))
                 ~status:(chain_http_error_status message) ~extra_headers:cors)
      | `GET, "/api/v1/command-plane/policy" ->
          let state = get_server_state () in
          let json = command_plane_policy_status_http_json ~state in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/operator" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () ->
                 let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
                 h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors)
          else
            let json = operator_snapshot_http_json ~state ~sw ~clock httpun_request in
            h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
      | `GET, "/api/v1/operator/digest" ->
          let state = get_server_state () in
          let path = Http.Request.path httpun_request in
          let respond_digest () =
            match operator_digest_http_json ~state ~sw ~clock httpun_request with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
            | Error message ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (operator_error_json message))
                  ~status:`Bad_request ~extra_headers:cors
          in
          if http_auth_strict_enabled () && not (is_public_read_path path) then
            (match authorize_read_request ~base_path:state.Mcp_server.room_config.base_path httpun_request with
             | Error err ->
                 let status = http_status_of_auth_error err in
                 h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
             | Ok () -> respond_digest ())
          else
            respond_digest ()
      | `GET, "/api/v1/status" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_state = Room.read_state config in
          let tempo = Tempo.get_tempo config in
          let json = `Assoc [
            ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
            ("project", `String room_state.project);
            ("tempo_interval_s", `Float tempo.current_interval_s);
            ("paused", `Bool room_state.paused);
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/credits" ->
          h2_respond_json h2_reqd (Credits_dashboard.json_api ()) ~extra_headers:cors

      | `GET, "/api/v1/openapi.json" ->
          let host_header = get_header_any_case httpun_request.headers "host" in
          let (resolved_host, resolved_port) = match host_header with
            | Some header -> parse_host_port (Some header) "127.0.0.1" 8935
            | None -> ("", 0)
          in
          let json =
            Transport.Rest.generate_openapi_document
              ~host:resolved_host ~port:resolved_port ()
            |> Yojson.Safe.to_string
          in
          h2_respond_json h2_reqd json ~extra_headers:cors

      | `GET, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_read_events_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          let room_id = Option.value ~default:"default" (Room.read_current_room config) in
          let json = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `POST, "/api/v1/room/current" ->
          let state = get_server_state () in
          let config = state.Mcp_server.room_config in
          h2_read_body h2_reqd (fun body_str ->
            try
              let json = Yojson.Safe.from_string body_str in
              (match trpg_parse_required_string "room_id" json with
               | Error (`Bad_request, msg) ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
               | Ok room_id ->
                   let room_id = String.trim room_id in
                   if room_id = "" then
                     h2_respond_json h2_reqd
                       (Yojson.Safe.to_string (trpg_error_json "room_id cannot be empty"))
                       ~status:`Bad_request ~extra_headers:cors
                   else (
                     Room.write_current_room config room_id;
                     Room.ensure_room_entry config room_id;
                     let response = `Assoc [("ok", `Bool true); ("room_id", `String room_id)] in
                     h2_respond_json h2_reqd (Yojson.Safe.to_string response) ~extra_headers:cors))
            with
            | Yojson.Json_error msg ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json (Printf.sprintf "invalid json: %s" msg)))
                  ~status:`Bad_request ~extra_headers:cors
            )

      | `POST, "/api/v1/operator/action" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operator_action" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_action_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_define" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_unit_define_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reparent" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_reparent" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reparent_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/units/reassign" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_unit_reassign" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_unit_reassign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_start" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_start_http_json ~state httpun_request
                        ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~status:`Created ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/checkpoint" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_checkpoint" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match
                      command_plane_operation_checkpoint_http_json ~state
                        httpun_request ~args
                    with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/pause" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_pause" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_pause_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/resume" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_resume" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_resume_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/stop" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_stop" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_stop_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/operations/finalize" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operation_finalize" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_operation_finalize_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/plan" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_plan" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_plan_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/assign" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_assign" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_assign_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/rebalance" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_rebalance" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_rebalance_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/escalate" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_escalate" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_escalate_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/recall" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_recall" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_recall_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/dispatch/tick" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_dispatch_tick" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_dispatch_tick_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/approve" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_approve" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_approve_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/deny" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_deny" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_deny_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/update" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_update" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_update_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/freeze" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_freeze_unit" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_freeze_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/command-plane/policy/kill-switch" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_policy_kill_switch" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match command_plane_policy_kill_switch_http_json ~state httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (command_plane_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (command_plane_error_json
                           (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/operator/confirm" ->
          let state = get_server_state () in
          (match h2_authorize_tool state ~tool_name:"masc_operator_confirm" with
           | Error err ->
               let status = http_status_of_auth_error err in
               h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
           | Ok () ->
               h2_read_body h2_reqd (fun body_str ->
                 try
                   let args = Yojson.Safe.from_string body_str in
                   (match operator_confirm_http_json ~state ~sw ~clock httpun_request ~args with
                    | Ok json ->
                        h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                          ~extra_headers:cors
                    | Error message ->
                        h2_respond_json h2_reqd
                          (Yojson.Safe.to_string (operator_error_json message))
                          ~status:`Bad_request ~extra_headers:cors)
                 with Yojson.Json_error msg ->
                   h2_respond_json h2_reqd
                     (Yojson.Safe.to_string
                        (operator_error_json (Printf.sprintf "invalid json: %s" msg)))
                     ~status:`Bad_request ~extra_headers:cors))

      | `POST, "/api/v1/trpg/events" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_append_event_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite" (query_param httpun_request "rule_module")
          in
          (match trpg_derive_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/catalog" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match
             trpg_lobby_catalog_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/lobby/preflight" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          let dm_keeper = query_param httpun_request "dm" in
          let player_keepers =
            query_param httpun_request "players" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          let models =
            query_param httpun_request "models" |> Option.value ~default:""
            |> split_csv_nonempty
          in
          (match
             trpg_lobby_preflight_json ~base_dir ~config:state.Mcp_server.room_config
               ~room_id ~rule_module ~dm_keeper ~player_keepers ~models
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/overview" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_overview_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/control/state" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let rule_module =
            Option.value ~default:"dnd5e-lite"
              (query_param httpun_request "rule_module")
          in
          (match trpg_control_state_json ~base_dir ~room_id ~rule_module with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/models" ->
          h2_respond_json h2_reqd
            (Yojson.Safe.to_string (trpg_available_models_json ()))
            ~extra_headers:cors

      | `POST, "/api/v1/trpg/dice/roll" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_dice_roll_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status:`Created
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/turns/advance" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_turn_advance_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `POST, "/api/v1/trpg/rounds/run" ->
          let state = get_server_state () in
          h2_read_body h2_reqd (fun body_str ->
            let agent_name =
              Option.value
                ~default:"dashboard"
                (agent_from_request httpun_request)
            in
            match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
            | Some sw, Some clock -> (
                match
                  trpg_round_run_json
                    ~state
                    ~agent_name
                    ~sw
                    ~clock
                    ~idempotency_key:
                      (get_header_any_case httpun_request.headers "idempotency-key")
                    ~body_str
                with
                | Ok json ->
                    h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                      ~extra_headers:cors
                | Error (`Bad_request, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Bad_request ~extra_headers:cors
                | Error (`Internal_server_error, msg) ->
                    h2_respond_json h2_reqd
                      (Yojson.Safe.to_string (trpg_error_json msg))
                      ~status:`Internal_server_error ~extra_headers:cors)
            | _ ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string
                     (trpg_error_json "trpg runtime not initialized"))
                  ~status:`Internal_server_error ~extra_headers:cors
          )

      | `GET, "/api/v1/trpg/stream" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          (match trpg_stream_json ~base_dir ~room_id ~after_seq ~event_type_filter with
          | Ok json ->
              let normalized = trpg_normalize_events_json ~default_room_id:room_id json in
              h2_respond_json h2_reqd (Yojson.Safe.to_string normalized) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/timeline" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id =
            trpg_resolve_room_id ~config:state.Mcp_server.room_config httpun_request in
          let after_seq = int_query_param httpun_request "after_seq" ~default:0 in
          let event_type_filter = query_param httpun_request "event_type" in
          let actor_filter = query_param httpun_request "actor" in
          let phase_filter = query_param httpun_request "phase" in
          let limit =
            int_query_param httpun_request "limit" ~default:50
            |> clamp ~min_v:1 ~max_v:200
          in
          (match
             trpg_timeline_json ~base_dir ~room_id ~after_seq ~event_type_filter
               ~actor_filter ~phase_filter ~limit
           with
          | Ok json ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors
          | Error (`Bad_request, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Bad_request ~extra_headers:cors
          | Error (`Internal_server_error, msg) ->
              h2_respond_json h2_reqd (Yojson.Safe.to_string (trpg_error_json msg))
                ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/trpg/stream/sse" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          let room_id = Option.value ~default:"" (query_param httpun_request "room_id") in
          let event_type_filter = query_param httpun_request "event_type" in
          let room_id_trimmed = String.trim room_id in
          if room_id_trimmed = "" then
            h2_respond_json h2_reqd
              (Yojson.Safe.to_string (trpg_error_json "room_id is required"))
              ~status:`Bad_request ~extra_headers:cors
          else begin
            match trpg_parse_event_type_filter event_type_filter with
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Ok event_type_opt ->
                let last_event_id =
                  match H2.Headers.get (H2.Reqd.request h2_reqd).headers "last-event-id" with
                  | Some id -> (try int_of_string id with Failure _ -> 0)
                  | None -> 0
                in
                let headers = H2.Headers.of_list ([
                  ("content-type", "text/event-stream");
                  ("cache-control", "no-cache");
                ] @ cors) in
                let response = H2.Response.create ~headers `OK in
                let writer = H2.Reqd.respond_with_streaming
                  ~flush_headers_immediately:true h2_reqd response in
                let closed = ref false in
                let last_seq = ref last_event_id in

                let send data =
                  if !closed || H2.Body.Writer.is_closed writer then begin
                    closed := true; false
                  end else begin
                    H2.Body.Writer.write_string writer data;
                    H2.Body.Writer.flush writer ignore;
                    true
                  end
                in

                let init_comment =
                  Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
                    room_id_trimmed !last_seq in
                ignore (send init_comment);

                (* Send existing events *)
                (match
                   (if !last_seq > 0 then
                      Trpg_engine_store_sqlite.read_events_after
                        ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                    else
                      Trpg_engine_store_sqlite.read_events
                        ~base_dir ~room_id:room_id_trimmed)
                 with
                 | Ok events ->
                     let events = match event_type_opt with
                       | None -> events
                       | Some et ->
                           List.filter (fun (ev : Trpg_engine_event.t) ->
                             ev.event_type = et) events
                     in
                     List.iter (fun ev ->
                       if not !closed then begin
                         ignore (send (trpg_event_to_sse ev));
                         last_seq := max !last_seq ev.Trpg_engine_event.seq
                       end) events
                 | Error _ -> ());

                (* Poll loop *)
                (match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
                 | Some sw, Some clock ->
                     Eio.Fiber.fork ~sw (fun () ->
                       let is_cancelled = function
                         | Eio.Cancel.Cancelled _ -> true | _ -> false in
                       let keepalive_counter = ref 0 in
                       let polls_per_keepalive =
                         max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s)) in
                       let rec loop () =
                         if not !closed then begin
                           (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                            with exn -> if is_cancelled exn then raise exn);
                           if not !closed then begin
                             (match
                                Trpg_engine_store_sqlite.read_events_after
                                  ~base_dir ~room_id:room_id_trimmed ~after_seq:!last_seq
                              with
                              | Ok events ->
                                  let events = match event_type_opt with
                                    | None -> events
                                    | Some et ->
                                        List.filter (fun (ev : Trpg_engine_event.t) ->
                                          ev.event_type = et) events
                                  in
                                  List.iter (fun ev ->
                                    if not !closed then begin
                                      if not (send (trpg_event_to_sse ev)) then
                                        closed := true
                                      else
                                        last_seq := max !last_seq
                                          ev.Trpg_engine_event.seq
                                    end) events
                              | Error _ -> ());
                             incr keepalive_counter;
                             if !keepalive_counter >= polls_per_keepalive then begin
                               keepalive_counter := 0;
                               if not !closed then ignore (send ": keepalive\n\n")
                             end
                           end;
                           loop ()
                         end else
                           H2.Body.Writer.close writer
                       in
                       try loop () with exn ->
                         if is_cancelled exn then raise exn
                         else
                           Log.Trpg.error "poll error for room %s: %s"
                             room_id_trimmed (Printexc.to_string exn))
                 | _ ->
                     ignore (send "event: error\ndata: {\"error\":\"server not ready\"}\n\n");
                     H2.Body.Writer.close writer)
          end

      | `POST, "/api/v1/trpg/actors/spawn" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match
              trpg_actor_spawn_json ~base_dir
                ~idempotency_key:
                  (get_header_any_case httpun_request.headers "idempotency-key")
                ~body_str
            with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/claim" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_claim_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~status:`Created ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/actors/release" ->
          let state = get_server_state () in
          let base_dir = state.Mcp_server.room_config.base_path in
          h2_read_body h2_reqd (fun body_str ->
            match trpg_actor_release_json ~base_dir ~body_str with
            | Ok json ->
                h2_respond_json h2_reqd (Yojson.Safe.to_string json)
                  ~extra_headers:cors
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `POST, "/api/v1/trpg/tts" ->
          h2_read_body h2_reqd (fun body_str ->
            match trpg_tts_proxy ~body_str with
            | Ok audio_bytes ->
                h2_respond_bytes ~content_type:"audio/mpeg"
                  ~extra_headers:cors h2_reqd audio_bytes
            | Error (`Bad_request, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Bad_request ~extra_headers:cors
            | Error (`Internal_server_error, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors
            | Error (_, msg) ->
                h2_respond_json h2_reqd
                  (Yojson.Safe.to_string (trpg_error_json msg))
                  ~status:`Internal_server_error ~extra_headers:cors)

      | `GET, "/api/v1/voice/config" ->
          let status, json = voice_config_payload () in
          let status =
            match status with `OK -> `OK | `Error -> `Internal_server_error
          in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~status
            ~extra_headers:cors

      | `GET, "/api/v1/governance/cases" ->
          let state = get_server_state () in
          let base_path = state.Mcp_server.room_config.base_path in
          let json = governance_cases_json httpun_request ~base_path in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, p
        when String.length p > 23
             && String.sub p 0 23 = "/api/v1/governance/cases/" ->
          let state = get_server_state () in
          let case_id = String.sub p 23 (String.length p - 23) in
          let base_path = state.Mcp_server.room_config.base_path in
          let (status, json) = governance_case_detail_json ~base_path ~case_id in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json)
            ~status ~extra_headers:cors

      | `GET, "/api/v1/board" ->
          let hearth = query_param httpun_request "hearth" in
          let sort_by = board_sort_order_of_request httpun_request in
          let exclude_system = bool_query_param httpun_request "exclude_system" ~default:false in
          let limit = int_query_param httpun_request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
          let offset = int_query_param httpun_request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
          let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
          let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
          let posts = filter_board_posts ~exclude_system posts in
          let karma_map = Board_dispatch.get_all_karma () in
          let get_karma author =
            Option.value ~default:0 (List.assoc_opt author karma_map)          in
          let paged = posts |> drop offset |> take limit in
          let posts_json = List.map (fun (p : Board.post) ->
            let author = Board.Agent_id.to_string p.author in
            board_post_dashboard_json ~author_karma:(get_karma author) p
          ) paged in
          let json = `Assoc [
            ("posts", `List posts_json);
            ("count", `Int (List.length posts_json));
            ("limit", `Int limit);
            ("offset", `Int offset);
            ("sort_by", `String (board_sort_label sort_by));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/hearths" ->
          let hearths = Board_dispatch.list_hearths () in
          let json = `Assoc [
            ("hearths", `List (List.map (fun (name, count) ->
              `Assoc [("name", `String name); ("count", `Int count)]
            ) hearths));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, "/api/v1/board/flairs" ->
          let flairs = List.map Board.flair_to_yojson Board.available_flairs in
          let json = `Assoc [("flairs", `List flairs)] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      | `GET, p when String.length p > 14 && String.sub p 0 14 = "/api/v1/board/" ->
          let post_id = String.sub p 14 (String.length p - 14) in
          let format = Option.value ~default:"nested" (query_param httpun_request "format") in
          let (status, body) = board_post_detail_json ~response_format:format ~post_id in
          h2_respond_json h2_reqd body ~status ~extra_headers:cors

      | `GET, "/api/v1/karma" ->
          let karma_list = Board_dispatch.get_all_karma () in
          let sorted = List.sort (fun (_, a) (_, b) -> compare b a) karma_list in
          let json = `Assoc [
            ("karma", `List (List.map (fun (agent, k) ->
              `Assoc [("agent", `String agent); ("karma", `Int k)]
            ) sorted));
          ] in
          h2_respond_json h2_reqd (Yojson.Safe.to_string json) ~extra_headers:cors

      (* ─────────────────────────────────────────────────────────────────────
         Static Assets
         ───────────────────────────────────────────────────────────────────── *)
      | `GET, "/static/css/middleware.css" ->
          (match read_file (playground_asset_path "static/css/middleware.css") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "text/css; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      | `GET, "/static/js/middleware.js" ->
          (match read_file (playground_asset_path "static/js/middleware.js") with
           | Ok body ->
               let headers = H2.Headers.of_list [
                 ("content-type", "application/javascript; charset=utf-8");
                 ("content-length", string_of_int (String.length body));
               ] in
               let response = H2.Response.create ~headers `OK in
               let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
               H2.Body.Writer.write_string writer body;
               H2.Body.Writer.close writer
           | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* Dashboard SPA: static assets *)
      | `GET, p when String.length p > 18
                   && String.sub p 0 18 = "/dashboard/assets/" ->
          let filename = String.sub p 18 (String.length p - 18) in
          if not (Web_dashboard.is_safe_asset_relative_path filename) then
            h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found
          else
            let file_path = Filename.concat (dashboard_asset_root ()) ("assets/" ^ filename) in
            (match read_file file_path with
             | Ok body ->
                 let ct = asset_content_type filename in
                 let headers = H2.Headers.of_list [
                   ("content-type", ct);
                   ("content-length", string_of_int (String.length body));
                   ("cache-control", "public, max-age=31536000, immutable");
                 ] in
                 let response = H2.Response.create ~headers `OK in
                 let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
                 H2.Body.Writer.write_string writer body;
                 H2.Body.Writer.close writer
             | Error _ -> h2_respond_text h2_reqd "404 Not Found" ~status:`Not_found)

      (* ─────────────────────────────────────────────────────────────────────
         Fallback
         ───────────────────────────────────────────────────────────────────── *)
      | _ ->
          h2_respond_text h2_reqd (Printf.sprintf "404 Not Found: %s" path) ~status:`Not_found ~extra_headers:cors

    in
    try
      if
        http_auth_strict_enabled ()
        && httpun_meth <> `OPTIONS
        && String.starts_with ~prefix:"/api/v1/trpg/" path
      then
        match authorize_read_request ~base_path httpun_request with
        | Ok () -> dispatch_h2_route ()
        | Error err ->
            let status = http_status_of_auth_error err in
            h2_respond_json h2_reqd (auth_error_json err) ~status ~extra_headers:cors
      else
        dispatch_h2_route ()
    with exn ->
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
