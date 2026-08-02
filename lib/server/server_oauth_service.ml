(* HIGH-RISK-UNREVIEWED: transport-neutral OAuth wire protocol service. *)

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

let query_params target =
  Uri.of_string target |> Uri.query |> Uri.encoded_of_query |> parse_form
;;

let param params name = List.assoc_opt name params

let oauth_error_description = function
  | Auth_oauth.Invalid_request message -> message
  | Auth_oauth.Invalid_client -> "client authentication failed"
  | Auth_oauth.Invalid_grant -> "authorization grant is invalid or expired"
  | Auth_oauth.Invalid_scope -> "requested scope is invalid"
  | Auth_oauth.Access_denied -> "authorization was denied"
  | Auth_oauth.OAuth_disabled -> "OAuth is disabled"
  | Auth_oauth.Temporarily_unavailable ->
    "authorization server is temporarily unavailable"
  | Auth_oauth.Store_error _ -> "authorization server state is unavailable"
;;

let oauth_error_status = function
  | Auth_oauth.Invalid_client -> `Unauthorized
  | Auth_oauth.OAuth_disabled | Auth_oauth.Temporarily_unavailable ->
    `Service_unavailable
  | Auth_oauth.Store_error _ -> `Internal_server_error
  | Auth_oauth.Invalid_request _
  | Auth_oauth.Invalid_grant
  | Auth_oauth.Invalid_scope
  | Auth_oauth.Access_denied ->
    `Bad_request
;;

let oauth_error_json error =
  `Assoc
    [ "error", `String (Auth_oauth.protocol_error_code error)
    ; "error_description", `String (oauth_error_description error)
    ]
;;

let hidden_input name value =
  Printf.sprintf
    {|<input type="hidden" name="%s" value="%s">|}
    (html_escape name)
    (html_escape value)
;;

let admin_scope_requested scopes =
  List.exists
    (function
      | Auth_oauth.Mcp_admin -> true
      | Auth_oauth.Mcp_tools -> false)
    scopes
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
  let client_label =
    match request.client_name with
    | Some name ->
      Printf.sprintf
        {|<strong>%s</strong> (<code>%s</code>)|}
        (html_escape name)
        (html_escape request.client_id)
    | None -> Printf.sprintf {|<code>%s</code>|} (html_escape request.client_id)
  in
  let scopes = Auth_oauth.scopes_to_string request.scopes |> html_escape in
  let admin_confirmation =
    if admin_scope_requested request.scopes
    then
      String.concat
        ""
        [ {|<p class="warning"><strong>Administrative access requested.</strong> This client will receive the <code>mcp:admin</code> scope.</p>|}
        ; {|<label><input name="confirm_admin" type="checkbox" value="yes" required> I explicitly approve administrative access.</label>|}
        ]
    else ""
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
        {|<p>Client %s will receive the callback at <code>%s</code>.</p>|}
        client_label
        (html_escape request.redirect_uri)
    ; Printf.sprintf
        {|<p>Requested scope: <code>%s</code>. Access tokens last up to %d seconds; refresh tokens last up to %d seconds.</p>|}
        scopes
        (Auth_oauth.access_token_ttl_sec ())
        (Auth_oauth.refresh_token_ttl_sec ())
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
    ; admin_confirmation
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

let authorize_get ~base_path ~authority ~target =
  let* params = query_params target in
  authorization_request_of_params ~base_path ~authority params
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

type authorization_post_outcome =
  | Authorization_redirect of string
  | Authorization_form_error of
      { status : [ `Bad_request | `Unauthorized ]
      ; message : string
      ; request : Auth_oauth.authorization_request
      }

let authorize_post ~base_path ~authority ~body =
  let* params = parse_form body in
  let* request = authorization_request_of_params ~base_path ~authority params in
  if
    admin_scope_requested request.scopes
    && not (Option.equal String.equal (param params "confirm_admin") (Some "yes"))
  then
    Ok
      (Authorization_form_error
         { status = `Bad_request
         ; message = "Administrative access requires explicit confirmation."
         ; request
         })
  else
    match param params "bootstrap_token" with
    | None ->
      Ok
        (Authorization_form_error
           { status = `Unauthorized
           ; message = "A MASC bearer is required."
           ; request
           })
    | Some bootstrap_token ->
      (match Auth.find_static_credential_by_token base_path ~token:bootstrap_token with
       | Error _ ->
         Ok
           (Authorization_form_error
              { status = `Unauthorized
              ; message = "The MASC bearer was not accepted."
              ; request
              })
       | Ok bootstrap_credential ->
         let* code =
           Auth_oauth.issue_authorization_code
             ~base_path
             ~request
             ~bootstrap_credential
         in
         Ok (Authorization_redirect (redirect_with_code request code)))
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

let ensure_optional_string_subset fields name supported =
  let* values = string_list_field fields name in
  match values with
  | None -> Ok ()
  | Some values
    when List.length values <> List.length (List.sort_uniq String.compare values) ->
    Error (Auth_oauth.Invalid_request (name ^ " contains duplicate values"))
  | Some values when List.for_all (fun value -> List.mem value supported) values -> Ok ()
  | Some _ -> Error (Auth_oauth.Invalid_request (name ^ " contains an unsupported value"))
;;

let register_client ~base_path body =
  if String.length body > max_request_body_bytes
  then Error (Auth_oauth.Invalid_request "request body is too large")
  else
    let* json =
      try Ok (Yojson.Safe.from_string body) with
      | Yojson.Json_error message -> Error (Auth_oauth.Invalid_request message)
    in
    match json with
    | `Assoc fields ->
      let* redirect_uris = string_list_field fields "redirect_uris" in
      let* redirect_uris =
        match redirect_uris with
        | Some values -> Ok values
        | None -> Error (Auth_oauth.Invalid_request "redirect_uris is required")
      in
      let* client_name = string_field fields "client_name" in
      let* () = ensure_optional_exact fields "token_endpoint_auth_method" "none" in
      let* () = ensure_optional_exact fields "application_type" "native" in
      let* () =
        ensure_optional_string_subset
          fields
          "grant_types"
          [ "authorization_code"; "refresh_token" ]
      in
      let* () = ensure_optional_string_subset fields "response_types" [ "code" ] in
      Auth_oauth.register_client ~base_path ~client_name ~redirect_uris
    | _ -> Error (Auth_oauth.Invalid_request "registration body must be an object")
;;

let registered_client_json (client : Auth_oauth.client) =
  `Assoc
    [ "client_id", `String client.client_id
    ; ( "client_name"
      , match client.client_name with None -> `Null | Some name -> `String name )
    ; "redirect_uris", `List (List.map (fun uri -> `String uri) client.redirect_uris)
    ; "grant_types", `List [ `String "authorization_code"; `String "refresh_token" ]
    ; "response_types", `List [ `String "code" ]
    ; "token_endpoint_auth_method", `String "none"
    ]
;;

let required params name =
  match param params name with
  | Some value when not (String.equal value "") -> Ok value
  | _ -> Error (Auth_oauth.Invalid_request (name ^ " is required"))
;;

let token ~base_path ~authority ~body =
  let* params = parse_form body in
  let* grant_type = required params "grant_type" in
  let* client_id = required params "client_id" in
  let expected_resource = Server_oauth_metadata.resource authority in
  match grant_type with
  | "authorization_code" ->
    let* code = required params "code" in
    let* redirect_uri = required params "redirect_uri" in
    let* code_verifier = required params "code_verifier" in
    Auth_oauth.exchange_authorization_code
      ~base_path
      ~expected_resource
      ~code
      ~client_id
      ~redirect_uri
      ~resource:(param params "resource")
      ~code_verifier
  | "refresh_token" ->
    let* refresh_token = required params "refresh_token" in
    Auth_oauth.rotate_refresh_token
      ~base_path
      ~expected_resource
      ~refresh_token
      ~client_id
      ~resource:(param params "resource")
  | _ -> Error (Auth_oauth.Invalid_request "grant_type is not supported")
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
