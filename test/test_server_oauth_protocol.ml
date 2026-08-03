open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-oauth-protocol-%d-%Ld"
         (Unix.getpid ())
         (Int64.bits_of_float (Unix.gettimeofday ())))
  in
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

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

let test_generic_bearer_challenge () =
  let cors = [ "vary", "Origin" ] in
  check
    (list (pair string string))
    "generic 401 advertises plain Bearer and preserves CORS"
    [ "www-authenticate", "Bearer"; "vary", "Origin" ]
    (Server_auth.auth_error_headers ~status:`Unauthorized ~cors);
  check
    (list (pair string string))
    "generic 403 preserves CORS without a challenge"
    cors
    (Server_auth.auth_error_headers ~status:`Forbidden ~cors)
;;

let test_public_listener_cannot_admit_loopback_oauth_by_host () =
  let trust_policy =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:"0.0.0.0"
        ~bind_port:8935
        ~explicit_base_url:(Some "http://127.0.0.1:8935")
    with
    | Ok policy -> policy
    | Error error ->
      fail (Server_request_authority.trust_policy_error_to_string error)
  in
  let request =
    Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "host", "127.0.0.1:8935" ])
      `GET
      "/.well-known/oauth-authorization-server"
  in
  match Server_request_authority.classify_http1_request ~trust_policy request with
  | Single authority ->
    check
      bool
      "explicit loopback Host does not expose OAuth on a public listener"
      false
      (Server_oauth_metadata.loopback_authority authority)
  | Missing | Multiple | Malformed | Untrusted ->
    fail "explicit loopback authority should be classified before OAuth admission"
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
    (Result.is_error (Server_oauth_service.parse_form "client_id=a&client_id=b"));
  check
    (list (pair string string))
    "single values parsed"
    [ "grant_type", "refresh_token"; "client_id", "codex" ]
    (match
       Server_oauth_service.parse_form "grant_type=refresh_token&client_id=codex"
     with
     | Ok values -> values
     | Error error -> fail (Auth_oauth.show_error error))
;;

let test_html_escape () =
  check
    string
    "attribute and text escaping"
    "&lt;&amp;&gt;&quot;&#39;"
    (Server_oauth_service.html_escape "<&>\"'")
;;

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let test_admin_consent_is_visible_and_explicit () =
  let request : Auth_oauth.authorization_request =
    { client_id = "masc_client"
    ; client_name = Some "Codex <Admin>"
    ; redirect_uri = "http://127.0.0.1:43123/callback"
    ; resource = "http://127.0.0.1:8935/mcp"
    ; scopes = [ Auth_oauth.Mcp_admin ]
    ; state = Some "state"
    ; code_challenge = String.make 43 'a'
    }
  in
  let html = Server_oauth_service.render_authorization_form request in
  check bool "verified client name is visible and escaped" true (contains html "Codex &lt;Admin&gt;");
  check bool "admin scope is visible" true (contains html "mcp:admin");
  check
    bool
    "admin approval requires a separate checkbox"
    true
    (contains html {|name="confirm_admin" type="checkbox" value="yes" required|});
  check
    bool
    "consent form offers an explicit denial callback"
    true
    (contains html {|name="decision" value="deny" formnovalidate|})
;;

let test_authorization_denial_redirects_with_state () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_workspace (fun base_path ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio_guard.enable ();
        Fun.protect
          ~finally:(fun () ->
            Eio_guard.disable ();
            Fs_compat.clear_fs ())
          (fun () ->
            let redirect_uri = "http://127.0.0.1:43132/callback/deny" in
            let client =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris:[ redirect_uri ]
              |> Result.get_ok
            in
            let body =
              Uri.encoded_of_query
                [ "response_type", [ "code" ]
                ; "client_id", [ client.client_id ]
                ; "redirect_uri", [ redirect_uri ]
                ; "resource", [ "http://127.0.0.1:8935/mcp" ]
                ; "scope", [ "mcp:tools" ]
                ; "state", [ "preserved-state" ]
                ; "code_challenge", [ String.make 43 'a' ]
                ; "code_challenge_method", [ "S256" ]
                ; "decision", [ "deny" ]
                ]
            in
            match
              Server_oauth_service.authorize_post
                ~base_path
                ~authority:(authority ())
                ~body
            with
            | Ok (Server_oauth_service.Authorization_redirect location) ->
              let callback = Uri.of_string location in
              check (option string) "denial error" (Some "access_denied")
                (Uri.get_query_param callback "error");
              check (option string) "denial preserves state" (Some "preserved-state")
                (Uri.get_query_param callback "state")
            | Ok (Server_oauth_service.Authorization_form_error _) ->
              fail "denial rendered a form error instead of redirecting"
            | Error error -> fail (Auth_oauth.show_error error)))))
;;

let grant_types values = [ "grant_types", `List (List.map (fun v -> `String v) values) ]
let supported_grant_types = [ "authorization_code"; "refresh_token" ]

let ensure_grant_types values =
  Server_oauth_service.ensure_optional_string_subset
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
       (Server_oauth_service.ensure_optional_string_subset
          []
          "grant_types"
          supported_grant_types))
;;

let () =
  run
    "server_oauth_protocol"
    [ ( "protocol"
      , [ test_case "Codex discovery contract" `Quick test_codex_discovery_contract
        ; test_case "generic Bearer challenge" `Quick test_generic_bearer_challenge
        ; test_case
            "public listener rejects loopback OAuth Host"
            `Quick
            test_public_listener_cannot_admit_loopback_oauth_by_host
        ; test_case
            "registration browser origin boundary"
            `Quick
            test_registration_browser_origin_boundary
        ; test_case "form ambiguity" `Quick test_form_parser_rejects_ambiguity
        ; test_case "HTML escaping" `Quick test_html_escape
        ; test_case
            "admin consent is visible and explicit"
            `Quick
            test_admin_consent_is_visible_and_explicit
        ; test_case
            "authorization denial redirects with state"
            `Quick
            test_authorization_denial_redirects_with_state
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
