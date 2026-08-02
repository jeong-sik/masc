(* HIGH-RISK-UNREVIEWED: OAuth HTTP/1 response adapter. *)

module Http = Http_server_eio

let respond_oauth_error request reqd error =
  Log.Misc.warn
    "oauth_http: request rejected error=%s"
    (Auth_oauth.protocol_error_code error);
  Http.Response.json_value
    ~status:(Server_oauth_service.oauth_error_status error :> Httpun.Status.t)
    ~request
    ~extra_headers:[ "cache-control", "no-store"; "pragma", "no-cache" ]
    (Server_oauth_service.oauth_error_json error)
    reqd
;;

let read_oauth_body request reqd callback =
  Http.Request.read_body_async_with_limit
    reqd
    ~max_bytes:Server_oauth_service.max_request_body_bytes
    ~on_body:callback
    ~on_error:(function
      | `Too_large _ ->
        respond_oauth_error
          request
          reqd
          (Auth_oauth.Invalid_request "request body is too large")
      | `Internal exn ->
        respond_oauth_error request reqd (Auth_oauth.Store_error (Printexc.to_string exn)))
;;

let respond_redirect location reqd =
  let response =
    Httpun.Response.create
      ~headers:
        (Httpun.Headers.of_list
           [ "location", location
           ; "content-length", "0"
           ; "cache-control", "no-store"
           ])
      `Found
  in
  Httpun.Reqd.respond_with_string reqd response ""
;;

let authority_opt () =
  let authority = Server_request_authority.current_exn () in
  if Auth_oauth.enabled () && Server_oauth_metadata.loopback_authority authority
  then Some authority
  else None
;;

let with_oauth_authority reqd handler =
  match authority_opt () with
  | Some authority -> handler authority
  | None -> Http.Response.not_found reqd
;;

let with_base_path request reqd handler =
  match Server_routes_http_common.current_server_state_opt () with
  | Some state -> handler (Mcp_server.workspace_config state).base_path
  | None -> respond_oauth_error request reqd Auth_oauth.Temporarily_unavailable
;;

let respond_authorization_form ?(status = `OK) ?error authorization_request reqd =
  Http.Response.html
    ~status
    ~headers:Server_oauth_service.authorization_form_headers
    (Server_oauth_service.render_authorization_form ?error authorization_request)
    reqd
;;

let handle_authorize_get request reqd =
  with_oauth_authority reqd (fun authority ->
    with_base_path request reqd (fun base_path ->
      match
        Server_oauth_service.authorize_get
          ~base_path
          ~authority
          ~target:request.Httpun.Request.target
      with
      | Error error -> respond_oauth_error request reqd error
      | Ok authorization_request ->
        respond_authorization_form authorization_request reqd))
;;

let handle_authorize_post request reqd =
  with_oauth_authority reqd (fun authority ->
    match
      Server_auth.ensure_same_origin_browser_request
        ~request_authority:authority
        request
    with
    | Error error -> Server_auth.respond_auth_error request reqd error
    | Ok () ->
      with_base_path request reqd (fun base_path ->
        read_oauth_body request reqd (fun body ->
          match Server_oauth_service.authorize_post ~base_path ~authority ~body with
          | Error error -> respond_oauth_error request reqd error
          | Ok (Server_oauth_service.Authorization_redirect location) ->
            respond_redirect location reqd
          | Ok
              (Server_oauth_service.Authorization_form_error
                 { status; message; request = authorization_request }) ->
            respond_authorization_form
              ~status:(status :> Httpun.Status.t)
              ~error:message
              authorization_request
              reqd)))
;;

let handle_register request reqd =
  with_oauth_authority reqd (fun authority ->
    match
      Server_auth.ensure_same_origin_if_browser_request
        ~request_authority:authority
        request
    with
    | Error error -> Server_auth.respond_auth_error request reqd error
    | Ok () ->
      with_base_path request reqd (fun base_path ->
        read_oauth_body request reqd (fun body ->
          match Server_oauth_service.register_client ~base_path body with
          | Error error -> respond_oauth_error request reqd error
          | Ok client ->
            Log.Misc.info "oauth_http: dynamic client registered";
            Http.Response.json_value
              ~status:`Created
              ~request
              ~extra_headers:[ "cache-control", "no-store" ]
              (Server_oauth_service.registered_client_json client)
              reqd)))
;;

let handle_token request reqd =
  with_oauth_authority reqd (fun authority ->
    match
      Server_auth.ensure_same_origin_if_browser_request
        ~request_authority:authority
        request
    with
    | Error error -> Server_auth.respond_auth_error request reqd error
    | Ok () ->
      with_base_path request reqd (fun base_path ->
        read_oauth_body request reqd (fun body ->
          match Server_oauth_service.token ~base_path ~authority ~body with
          | Error error -> respond_oauth_error request reqd error
          | Ok pair ->
            Log.Misc.info "oauth_http: token grant completed";
            Http.Response.json_value
              ~request
              ~extra_headers:[ "cache-control", "no-store"; "pragma", "no-cache" ]
              (Server_oauth_service.token_pair_json pair)
              reqd)))
;;

let handle_protected_resource request reqd =
  with_oauth_authority reqd (fun authority ->
    Http.Response.json_value
      ~request
      ~extra_headers:[ "cache-control", "no-store" ]
      (Server_oauth_metadata.protected_resource_json authority)
      reqd)
;;

let handle_authorization_server request reqd =
  with_oauth_authority reqd (fun authority ->
    Http.Response.json_value
      ~request
      ~extra_headers:[ "cache-control", "no-store" ]
      (Server_oauth_metadata.authorization_server_json authority)
      reqd)
;;

let add_routes router =
  router
  |> Http.Router.get
       "/.well-known/oauth-protected-resource"
       handle_protected_resource
  |> Http.Router.get
       "/.well-known/oauth-protected-resource/mcp"
       handle_protected_resource
  |> Http.Router.get
       "/mcp/.well-known/oauth-protected-resource"
       handle_protected_resource
  |> Http.Router.get
       "/.well-known/oauth-authorization-server"
       handle_authorization_server
  |> Http.Router.get "/oauth/authorize" handle_authorize_get
  |> Http.Router.post "/oauth/authorize" handle_authorize_post
  |> Http.Router.post "/oauth/register" handle_register
  |> Http.Router.post "/oauth/token" handle_token
;;
