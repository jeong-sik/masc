module Http = Http_server_eio
module Mcp_eio = Mcp_server_eio

type deps = Server_mcp_transport_http_types.deps

let handle_get_operator_mcp ~(deps : deps) request reqd =
  let session_id =
    Mcp_session.get_or_generate
      (Server_mcp_transport_http_session.get_session_id_any request)
  in
  let protocol_version =
    Server_mcp_transport_http_session.get_protocol_version_for_session
      ~session_id request
  in
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> Server_mcp_transport_http_session.default_base_path ()
  in
  match deps.verify_operator_mcp_auth ~base_path request with
  | Error msg ->
      Server_mcp_transport_http_headers.respond_mcp_auth_error ~deps request
        reqd ~session_id ~protocol_version msg
  | Ok () ->
      Server_mcp_transport_http_mcp_handlers.handle_get_mcp ~deps
        ~profile:Mcp_eio.Operator_remote request reqd

let handle_post_messages ~(deps : deps) request reqd =
  let origin = deps.get_origin request in
  let legacy_headers =
    Server_mcp_transport_http_headers.legacy_transport_deprecation_headers
  in
  match Server_mcp_transport_http_session.get_session_id_any request with
  | None ->
      let body = "session_id required" in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: (legacy_headers @ deps.cors_headers origin))
      in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id when not (Mcp_session.is_valid session_id) ->
      let body = "invalid session_id" in
      let headers =
        Httpun.Headers.of_list
          (("content-length", string_of_int (String.length body))
          :: (legacy_headers @ deps.cors_headers origin))
      in
      let response = Httpun.Response.create ~headers `Bad_request in
      Httpun.Reqd.respond_with_string reqd response body
  | Some session_id ->
      let protocol_version =
        Server_mcp_transport_http_session.get_protocol_version_for_session
          ~session_id request
      in
      let auth_token = deps.auth_token_from_request request in
      let base_path =
        match deps.get_server_state_opt () with
        | Some s -> s.Mcp_server.room_config.base_path
        | None -> Server_mcp_transport_http_session.default_base_path ()
      in
      (match deps.verify_mcp_auth ~base_path request with
      | Error msg ->
          Server_mcp_transport_http_headers.respond_mcp_auth_error ~deps request
            reqd ~session_id ~protocol_version ~extra_headers:legacy_headers
            msg
      | Ok () ->
          Http.Request.read_body_async reqd (fun body_str ->
              match
                Server_mcp_transport_http_headers.request_runtime_result deps
              with
              | Error msg ->
                  Server_mcp_transport_http_headers.respond_mcp_internal_error
                    ~extra_headers:legacy_headers ~deps request reqd
                    ~session_id ~protocol_version msg
              | Ok (state, sw, clock) ->
                  let response_json =
                    Mcp_eio.handle_request ~clock ~sw
                      ~mcp_session_id:session_id ?auth_token state body_str
                  in
                  (match response_json with
                  | `Null -> ()
                  | json -> Sse.send_to session_id json);
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", "0")
                      :: (legacy_headers
                         @ Server_mcp_transport_http_headers.mcp_headers
                             session_id protocol_version))
                  in
                  let response = Httpun.Response.create ~headers `Accepted in
                  Httpun.Reqd.respond_with_string reqd response ""))

let handle_delete_mcp ~(deps : deps) ?(profile = Mcp_eio.Full) request reqd =
  let base_path =
    match deps.get_server_state_opt () with
    | Some s -> s.Mcp_server.room_config.base_path
    | None -> Server_mcp_transport_http_session.default_base_path ()
  in
  let auth_result =
    match profile with
    | Mcp_eio.Full | Mcp_eio.Managed_agent -> Ok ()
    | Mcp_eio.Operator_remote ->
        deps.verify_operator_mcp_auth ~base_path request
  in
  match auth_result with
  | Error msg ->
      let session_id =
        Mcp_session.get_or_generate
          (Server_mcp_transport_http_session.get_session_id_any request)
      in
      let protocol_version =
        Server_mcp_transport_http_session.get_protocol_version_for_session
          ~session_id request
      in
      Server_mcp_transport_http_headers.respond_mcp_auth_error ~deps request
        reqd ~session_id ~protocol_version msg
  | Ok () ->
      match Server_mcp_transport_http_session.get_session_id_any request with
      | None ->
          let body = "Mcp-Session-Id required" in
          let headers =
            Httpun.Headers.of_list
              [ ("content-length", string_of_int (String.length body)) ]
          in
          let response = Httpun.Response.create ~headers `Bad_request in
          Httpun.Reqd.respond_with_string reqd response body
      | Some session_id -> (
          match
            Server_mcp_transport_http_session
            .validate_mcp_session_delete_profile ~profile session_id
          with
          | Error msg ->
              let headers =
                Httpun.Headers.of_list
                  [ ("content-length", string_of_int (String.length msg)) ]
              in
              let response = Httpun.Response.create ~headers `Conflict in
              Httpun.Reqd.respond_with_string reqd response msg
          | Ok () -> (
              match
                Server_mcp_transport_http_session
                .validate_protocol_version_continuity ~session_id request
              with
              | Error msg ->
                  let body =
                    Printf.sprintf
                      {|{"jsonrpc":"2.0","error":{"code":-32600,"message":%s},"id":null}|}
                      (Yojson.Safe.to_string (`String msg))
                  in
                  let protocol_version =
                    Server_mcp_transport_http_session
                    .get_protocol_version_for_session ~session_id request
                  in
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", string_of_int (String.length body))
                      :: Server_mcp_transport_http_headers.json_headers ~deps
                           session_id protocol_version (deps.get_origin request))
                  in
                  let response =
                    Httpun.Response.create ~headers `Bad_request
                  in
                  Httpun.Reqd.respond_with_string reqd response body
              | Ok () ->
                  Server_mcp_transport_http_sse.stop_sse_session session_id;
                  Sse.unregister session_id;
                  Mcp_eio.clear_resource_subscriptions_for_session session_id;
                  Server_mcp_transport_http_session.forget_mcp_session session_id;
                  Printf.printf "🔚 Session terminated: %s\n%!" session_id;
                  let headers =
                    Httpun.Headers.of_list
                      (("content-length", "0")
                      :: Server_mcp_transport_http_headers.mcp_headers
                           session_id
                           (Server_mcp_transport_http_session
                            .get_protocol_version request))
                  in
                  let response =
                    Httpun.Response.create ~headers `No_content
                  in
                  Httpun.Reqd.respond_with_string reqd response ""))
