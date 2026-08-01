open Alcotest

let authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "loopback authority must be valid"
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv name previous
      | None -> Unix.unsetenv name)
    f
;;

let test_codex_discovery_contract () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    let authority = authority () in
    check
      string
      "resource"
      "http://127.0.0.1:8935/mcp"
      (Server_oauth_metadata.resource authority);
    check
      string
      "root protected-resource discovery"
      "http://127.0.0.1:8935/.well-known/oauth-protected-resource"
      (Server_oauth_metadata.protected_resource_metadata_url authority);
    check
      string
      "Codex bearer challenge"
      "Bearer resource_metadata=\"http://127.0.0.1:8935/.well-known/oauth-protected-resource\", scope=\"mcp:tools\""
      (Server_oauth_metadata.challenge_for_authority authority);
    let metadata = Server_oauth_metadata.authorization_server_json authority in
    let fields = Yojson.Safe.Util.to_assoc metadata in
    check
      bool
      "does not advertise authorization response iss"
      false
      (List.mem_assoc "authorization_response_iss_parameter_supported" fields);
    check
      (list string)
      "PKCE S256 only"
      [ "S256" ]
      (Yojson.Safe.Util.member "code_challenge_methods_supported" metadata
       |> Yojson.Safe.Util.to_list
       |> List.map Yojson.Safe.Util.to_string);
    let resource_metadata = Server_oauth_metadata.protected_resource_json authority in
    check
      bool
      "does not advertise a dead documentation URL"
      false
      (Yojson.Safe.Util.to_assoc resource_metadata
       |> List.mem_assoc "resource_documentation"))
;;

let registration_request ?origin () =
  let headers =
    ("host", "127.0.0.1:8935")
    :: (match origin with None -> [] | Some value -> [ "origin", value ])
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `POST
    "/oauth/register"
;;

let test_registration_browser_origin_boundary () =
  let authority = authority () in
  check
    bool
    "native registration without Origin remains admitted"
    true
    (Server_auth.ensure_same_origin_if_browser_request
       ~request_authority:authority
       (registration_request ())
     |> Result.is_ok);
  check
    bool
    "same-origin browser registration remains admitted"
    true
    (Server_auth.ensure_same_origin_if_browser_request
       ~request_authority:authority
       (registration_request ~origin:"http://127.0.0.1:8935" ())
     |> Result.is_ok);
  check
    bool
    "cross-origin browser registration is rejected before allocation"
    true
    (Server_auth.ensure_same_origin_if_browser_request
       ~request_authority:authority
       (registration_request ~origin:"https://evil.example" ())
     |> Result.is_error)
;;

let test_form_parser_rejects_ambiguity () =
  check
    bool
    "duplicate parameter rejected"
    true
    (Result.is_error (Server_oauth_http.parse_form "client_id=a&client_id=b"));
  check
    (list (pair string string))
    "single values parsed"
    [ "grant_type", "refresh_token"; "client_id", "codex" ]
    (match
       Server_oauth_http.parse_form "grant_type=refresh_token&client_id=codex"
     with
     | Ok values -> values
     | Error error -> fail (Auth_oauth.show_error error))
;;

let test_html_escape () =
  check
    string
    "attribute and text escaping"
    "&lt;&amp;&gt;&quot;&#39;"
    (Server_oauth_http.html_escape "<&>\"'")
;;

let grant_types values = [ "grant_types", `List (List.map (fun v -> `String v) values) ]
let supported_grant_types = [ "authorization_code"; "refresh_token" ]

let ensure_grant_types values =
  Server_oauth_http.ensure_optional_string_subset
    (grant_types values)
    "grant_types"
    supported_grant_types
;;

let test_string_subset_rejects_duplicates () =
  check
    bool
    "a value repeated twice does not stand in for a second grant"
    true
    (Result.is_error (ensure_grant_types [ "authorization_code"; "authorization_code" ]))
;;

let test_string_subset_rejects_unsupported () =
  check
    bool
    "a grant this server does not implement is refused"
    true
    (Result.is_error (ensure_grant_types [ "authorization_code"; "client_credentials" ]))
;;

(* RFC 7591 §2: omitting [grant_types] means exactly ["authorization_code"], so
   naming that one value must register just as the omission does. *)
let test_string_subset_accepts_documented_default () =
  check
    bool
    "declaring only the default grant registers"
    true
    (Result.is_ok (ensure_grant_types [ "authorization_code" ]));
  check
    bool
    "omitting the field registers"
    true
    (Result.is_ok
       (Server_oauth_http.ensure_optional_string_subset
          []
          "grant_types"
          supported_grant_types))
;;

let () =
  run
    "server_oauth_protocol"
    [ ( "protocol"
      , [ test_case "Codex discovery contract" `Quick test_codex_discovery_contract
        ; test_case
            "registration browser origin boundary"
            `Quick
            test_registration_browser_origin_boundary
        ; test_case "form ambiguity" `Quick test_form_parser_rejects_ambiguity
        ; test_case "HTML escaping" `Quick test_html_escape
        ; test_case
            "string subset rejects duplicates"
            `Quick
            test_string_subset_rejects_duplicates
        ; test_case
            "string subset rejects unsupported"
            `Quick
            test_string_subset_rejects_unsupported
        ; test_case
            "string subset accepts documented default"
            `Quick
            test_string_subset_accepts_documented_default
        ] )
    ]
;;
