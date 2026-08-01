(* HIGH-RISK-UNREVIEWED: OAuth browser, registration, and token endpoints.
   Human security review is required before this marker may be removed. *)

module Http = Http_server_eio

let ( let* ) = Result.bind
let max_request_body_bytes = 16 * 1024

let html_escape value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (function
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&#39;"
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.contents buffer
;;

let parse_form encoded =
  if String.length encoded > max_request_body_bytes
  then Error (Auth_oauth.Invalid_request "request body is too large")
  else
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | (name, [ value ]) :: rest ->
        if List.mem_assoc name acc
        then Error (Auth_oauth.Invalid_request ("duplicate parameter: " ^ name))
        else collect ((name, value) :: acc) rest
      | (name, []) :: _ ->
        Error (Auth_oauth.Invalid_request ("parameter has no value: " ^ name))
      | (name, _ :: _ :: _) :: _ ->
        Error (Auth_oauth.Invalid_request ("duplicate parameter: " ^ name))
    in
    collect [] (Uri.query_of_encoded encoded)
;;

let query_params request =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.query uri |> Uri.encoded_of_query |> parse_form
;;

let param params name = List.assoc_opt name params

let oauth_error_description = function
  | Auth_oauth.Invalid_request message -> message
  | Invalid_client -> "client authentication failed"
  | Invalid_grant -> "authorization grant is invalid or expired"
  | Invalid_scope -> "requested scope is invalid"
  | Access_denied -> "authorization was denied"
  | OAuth_disabled -> "OAuth is disabled"
  | Temporarily_unavailable -> "authorization server is temporarily unavailable"
  | Store_error _ -> "authorization server state is unavailable"
;;

let oauth_error_status = function
  | Auth_oauth.Invalid_client -> `Unauthorized
  | OAuth_disabled | Temporarily_unavailable -> `Service_unavailable
  | Store_error _ -> `Internal_server_error
  | Invalid_request _ | Invalid_grant | Invalid_scope | Access_denied -> `Bad_request
;;

let respond_oauth_error request reqd error =
  Log.Misc.warn
    "oauth_http: request rejected error=%s"
    (Auth_oauth.protocol_error_code error);
  Http.Response.json_value
    ~status:(oauth_error_status error)
    ~request
    ~extra_headers:[ "cache-control", "no-store"; "pragma", "no-cache" ]
    (`Assoc
      [ "error", `String (Auth_oauth.protocol_error_code error)
      ; "error_description", `String (oauth_error_description error)
      ])
    reqd
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

let with_oauth_authority request reqd handler =
  match authority_opt () with
  | Some authority -> handler authority
  | None -> Http.Response.not_found reqd
;;

let with_base_path request reqd handler =
  match Server_routes_http_common.current_server_state_opt () with
  | Some state ->
    handler (Mcp_server.workspace_config state).base_path
  | None ->
    respond_oauth_error request reqd Auth_oauth.Temporarily_unavailable
;;

let hidden_input name value =
  Printf.sprintf
    {|<input type="hidden" name="%s" value="%s">|}
    (html_escape name)
    (html_escape value)
;;

let render_authorization_form ?error (request : Auth_oauth.authorization_request) =
  let error_html =
    match error with
    | None -> ""
    | Some message ->
      Printf.sprintf {|<p class="error" role="alert">%s</p>|} (html_escape message)
  in
  let state_input =
    match request.state with
    | None -> ""
    | Some value -> hidden_input "state" value
  in
  String.concat
    ""
    [ {|<!doctype html><html lang="en"><head><meta charset="utf-8">|}
    ; {|<meta name="viewport" content="width=device-width,initial-scale=1">|}
    ; {|<title>Authorize MCP access to MASC</title>|}
    ; {|<style>body{font-family:system-ui;max-width:34rem;margin:4rem auto;padding:0 1rem}|}
    ; {|label,input,button{display:block;width:100%;box-sizing:border-box}input,button{padding:.75rem;margin-top:.5rem}.error{color:#b42318}</style>|}
    ; {|</head><body><h1>Authorize MCP access</h1>|}
    ; Printf.sprintf
        {|<p>Client <code>%s</code> will receive the callback at <code>%s</code>.</p>|}
        (html_escape request.client_id)
        (html_escape request.redirect_uri)
    ; {|<p>Enter an existing MASC bearer once to bind this OAuth session to its agent identity.</p>|}
    ; error_html
    ; {|<form method="post" action="/oauth/authorize">|}
    ; hidden_input "response_type" "code"
    ; hidden_input "client_id" request.client_id
    ; hidden_input "redirect_uri" request.redirect_uri
    ; hidden_input "resource" request.resource
    ; hidden_input "scope" (Auth_oauth.scopes_to_string request.scopes)
    ; state_input
    ; hidden_input "code_challenge" request.code_challenge
    ; hidden_input "code_challenge_method" "S256"
    ; {|<label for="bootstrap_token">MASC bearer</label>|}
    ; {|<input id="bootstrap_token" name="bootstrap_token" type="password" autocomplete="off" required>|}
    ; {|<button type="submit">Authorize</button></form></body></html>|}
    ]
;;

let authorization_form_headers =
  [ "cache-control", "no-store"
  ; ( "content-security-policy"
    , "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'" )
  ; "x-frame-options", "DENY"
  ]
;;

let respond_authorization_form ?(status = `OK) ?error authorization_request reqd =
  Http.Response.html
    ~status
    ~headers:authorization_form_headers
    (render_authorization_form ?error authorization_request)
    reqd
;;

let authorization_request_of_params ~base_path ~authority params =
  Auth_oauth.validate_authorization_request
    ~base_path
    ~expected_resource:(Server_oauth_metadata.resource authority)
    ~response_type:(param params "response_type")
    ~client_id:(param params "client_id")
    ~redirect_uri:(param params "redirect_uri")
    ~resource:(param params "resource")
    ~scope:(param params "scope")
    ~state:(param params "state")
    ~code_challenge:(param params "code_challenge")
    ~code_challenge_method:(param params "code_challenge_method")
;;

let handle_authorize_get request reqd =
  with_oauth_authority request reqd (fun authority ->
    Log.Misc.debug "oauth_http: authorization form requested";
    with_base_path request reqd (fun base_path ->
      match query_params request with
      | Error error -> respond_oauth_error request reqd error
      | Ok params ->
        (match authorization_request_of_params ~base_path ~authority params with
         | Error error -> respond_oauth_error request reqd error
         | Ok authorization_request ->
           respond_authorization_form authorization_request reqd)))
;;

let redirect_with_code authorization_request code =
  let params =
    ("code", code)
    :: (match authorization_request.Auth_oauth.state with
        | None -> []
        | Some state -> [ "state", state ])
  in
  Uri.of_string authorization_request.redirect_uri
  |> fun uri -> Uri.add_query_params' uri params
  |> Uri.to_string
;;

let handle_authorize_post request reqd =
  with_oauth_authority request reqd (fun authority ->
    match Server_auth.ensure_same_origin_browser_request ~request_authority:authority request with
    | Error error -> Server_auth.respond_auth_error request reqd error
    | Ok () ->
      with_base_path request reqd (fun base_path ->
        Http.Request.read_body_async reqd (fun body ->
          match parse_form body with
          | Error error -> respond_oauth_error request reqd error
          | Ok params ->
            (match authorization_request_of_params ~base_path ~authority params with
             | Error error -> respond_oauth_error request reqd error
             | Ok authorization_request ->
               (match param params "bootstrap_token" with
                | None ->
                  Log.Auth.warn "oauth: bootstrap bearer missing";
                  respond_authorization_form
                    ~status:`Unauthorized
                    ~error:"A MASC bearer is required."
                    authorization_request
                    reqd
                | Some bootstrap_token ->
                  (match Auth.find_static_credential_by_token base_path ~token:bootstrap_token with
                   | Error error ->
                     Log.Auth.warn
                       "oauth: bootstrap bearer rejected reason=%s"
                       (Masc_domain.masc_error_to_string error);
                     respond_authorization_form
                       ~status:`Unauthorized
                       ~error:"The MASC bearer was not accepted."
                       authorization_request
                       reqd
                   | Ok bootstrap_credential ->
                     (match
                        Auth_oauth.issue_authorization_code
                          ~base_path
                          ~request:authorization_request
                          ~bootstrap_credential
                      with
                      | Error error -> respond_oauth_error request reqd error
                      | Ok code ->
                        Log.Misc.info
                          "oauth_http: authorization code issued agent=%s"
                          bootstrap_credential.agent_name;
                        respond_redirect
                          (redirect_with_code authorization_request code)
                          reqd)))))))
;;

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok (Some value)
  | None -> Ok None
  | Some _ -> Error (Auth_oauth.Invalid_request (name ^ " must be a string"))
;;

let string_list_field fields name =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    let rec collect acc = function
      | [] -> Ok (Some (List.rev acc))
      | `String value :: rest -> collect (value :: acc) rest
      | _ :: _ -> Error (Auth_oauth.Invalid_request (name ^ " must contain strings"))
    in
    collect [] values
  | None -> Ok None
  | Some _ -> Error (Auth_oauth.Invalid_request (name ^ " must be an array"))
;;

let ensure_optional_exact fields name expected =
  let* value = string_field fields name in
  match value with
  | None -> Ok ()
  | Some value when String.equal value expected -> Ok ()
  | Some _ -> Error (Auth_oauth.Invalid_request (name ^ " is not supported"))
;;

let ensure_optional_string_set fields name expected =
  let* values = string_list_field fields name in
  match values with
  | None -> Ok ()
  | Some values
    when List.length values = List.length expected
         && List.for_all (fun value -> List.mem value expected) values ->
    Ok ()
  | Some _ -> Error (Auth_oauth.Invalid_request (name ^ " is not supported"))
;;

let handle_register request reqd =
  with_oauth_authority request reqd (fun _authority ->
    with_base_path request reqd (fun base_path ->
      Http.Request.read_body_async reqd (fun body ->
        if String.length body > max_request_body_bytes
        then
          respond_oauth_error
            request
            reqd
            (Auth_oauth.Invalid_request "request body is too large")
        else
          let parsed =
            try Ok (Yojson.Safe.from_string body) with
            | Yojson.Json_error message -> Error (Auth_oauth.Invalid_request message)
          in
          match parsed with
          | Error error -> respond_oauth_error request reqd error
          | Ok (`Assoc fields) ->
            let result =
              let* redirect_uris = string_list_field fields "redirect_uris" in
              let* redirect_uris =
                match redirect_uris with
                | Some values -> Ok values
                | None -> Error (Auth_oauth.Invalid_request "redirect_uris is required")
              in
              let* client_name = string_field fields "client_name" in
              let* () =
                ensure_optional_exact fields "token_endpoint_auth_method" "none"
              in
              let* () = ensure_optional_exact fields "application_type" "native" in
              let* () =
                ensure_optional_string_set
                  fields
                  "grant_types"
                  [ "authorization_code"; "refresh_token" ]
              in
              let* () = ensure_optional_string_set fields "response_types" [ "code" ] in
              Auth_oauth.register_client ~base_path ~client_name ~redirect_uris
            in
            (match result with
             | Error error -> respond_oauth_error request reqd error
             | Ok client ->
               Log.Misc.info "oauth_http: dynamic client registered";
               Http.Response.json_value
                 ~status:`Created
                 ~request
                 ~extra_headers:[ "cache-control", "no-store" ]
                 (`Assoc
                   [ "client_id", `String client.client_id
                   ; "client_name", (match client.client_name with None -> `Null | Some name -> `String name)
                   ; "redirect_uris", `List (List.map (fun uri -> `String uri) client.redirect_uris)
                   ; "grant_types", `List [ `String "authorization_code"; `String "refresh_token" ]
                   ; "response_types", `List [ `String "code" ]
                   ; "token_endpoint_auth_method", `String "none"
                   ])
                 reqd)
          | Ok _ ->
            respond_oauth_error
              request
              reqd
              (Auth_oauth.Invalid_request "registration body must be an object"))))
;;

let token_pair_json pair =
  `Assoc
    [ "access_token", `String pair.Auth_oauth.access_token
    ; "refresh_token", `String pair.refresh_token
    ; "token_type", `String pair.token_type
    ; "expires_in", `Int pair.expires_in
    ; "scope", `String pair.scope
    ]
;;

let handle_token request reqd =
  with_oauth_authority request reqd (fun authority ->
    with_base_path request reqd (fun base_path ->
      Http.Request.read_body_async reqd (fun body ->
        match parse_form body with
        | Error error -> respond_oauth_error request reqd error
        | Ok params ->
          let required name =
            match param params name with
            | Some value when not (String.equal value "") -> Ok value
            | _ -> Error (Auth_oauth.Invalid_request (name ^ " is required"))
          in
          let expected_resource = Server_oauth_metadata.resource authority in
          let result =
            let* grant_type = required "grant_type" in
            let* client_id = required "client_id" in
            match grant_type with
            | "authorization_code" ->
              let* code = required "code" in
              let* redirect_uri = required "redirect_uri" in
              let* code_verifier = required "code_verifier" in
              Auth_oauth.exchange_authorization_code
                ~base_path
                ~expected_resource
                ~code
                ~client_id
                ~redirect_uri
                ~resource:(param params "resource")
                ~code_verifier
            | "refresh_token" ->
              let* refresh_token = required "refresh_token" in
              Auth_oauth.rotate_refresh_token
                ~base_path
                ~expected_resource
                ~refresh_token
                ~client_id
                ~resource:(param params "resource")
            | _ -> Error (Auth_oauth.Invalid_request "grant_type is not supported")
          in
          match result with
          | Error error -> respond_oauth_error request reqd error
          | Ok pair ->
            Log.Misc.info "oauth_http: token grant completed";
            Http.Response.json_value
              ~request
              ~extra_headers:[ "cache-control", "no-store"; "pragma", "no-cache" ]
              (token_pair_json pair)
              reqd)))
;;

let handle_protected_resource request reqd =
  with_oauth_authority request reqd (fun authority ->
    Log.Misc.debug "oauth_http: protected resource metadata requested";
    Http.Response.json_value
      ~request
      ~extra_headers:[ "cache-control", "no-store" ]
      (Server_oauth_metadata.protected_resource_json authority)
      reqd)
;;

let handle_authorization_server request reqd =
  with_oauth_authority request reqd (fun authority ->
    Log.Misc.debug "oauth_http: authorization server metadata requested";
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
