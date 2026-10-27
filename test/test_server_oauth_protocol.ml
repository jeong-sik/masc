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

let no_document _ = Error "this fixture fetches no document"

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
      (option bool)
      "advertises authorization response iss (RFC 9207)"
      (Some true)
      (match List.assoc_opt "authorization_response_iss_parameter_supported" fields with
       | Some (`Bool value) -> Some value
       | Some _ | None -> None);
    check
      (option string)
      "metadata issuer is the iss every authorization response carries"
      (Some (Server_oauth_metadata.issuer authority))
      (match List.assoc_opt "issuer" fields with
       | Some (`String value) -> Some value
       | Some _ | None -> None);
    check
      (option bool)
      "advertises Client ID Metadata Documents (MCP 2026-07-28)"
      (Some true)
      (match List.assoc_opt "client_id_metadata_document_supported" fields with
       | Some (`Bool value) -> Some value
       | Some _ | None -> None);
    check
      (list string)
      "PKCE S256 only"
      [ "S256" ]
      (Yojson.Safe.Util.member "code_challenge_methods_supported" metadata
       |> Yojson.Safe.Util.to_list
       |> List.map Yojson.Safe.Util.to_string);
    (match Server_request_authority.of_host_port ~host:"localhost" ~port:9000 with
     | Ok other ->
       check
         string
         "issuer follows the admitted authority"
         "http://localhost:9000"
         (Server_oauth_metadata.issuer other)
     | Error `Malformed -> fail "localhost authority must be valid");
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

let test_listener_scope_survives_wire_projection () =
  List.iter
    (fun (bind_host, wire_host, expected) ->
      let trust_policy =
        match Server_request_authority.make_trust_policy
          ~bind_host ~bind_port:8935 ~explicit_base_url:None with
        | Ok policy -> policy
        | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
      in
      let check_authority label authority =
        check bool (bind_host ^ " " ^ label) expected
          (Server_oauth_metadata.loopback_authority authority)
      in
      check_authority "background" (Server_request_authority.projection_context trust_policy);
      let wire = wire_host ^ ":8935" in
      let http1 = Httpun.Request.create
        ~headers:(Httpun.Headers.of_list [ "host", wire ]) `GET "/mcp" in
      (match Server_request_authority.classify_http1_request ~trust_policy http1 with
       | Single authority -> check_authority "HTTP/1" authority
       | _ -> fail "configured local wire identity must remain admitted");
      let http2 = H2.Request.create ~scheme:"http"
        ~headers:(H2.Headers.of_list [ ":authority", wire ]) `GET "/mcp" in
      match Server_request_authority.classify_h2_request ~trust_policy http2 with
      | H2_authority (Single authority) -> check_authority "HTTP/2" authority
      | _ -> fail "configured local HTTP/2 identity must remain admitted")
    [ "0.0.0.0", "127.0.0.1", false
    ; "::", "127.0.0.1", false
    ; "127.0.0.1", "127.0.0.1", true
    ; "::1", "[::1]", true
    ]
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
  (match
     Server_auth.ensure_same_origin_if_browser_request
       ~request_authority:authority
       (registration_request ~origin:"https://evil.example" ())
   with
   | Error (Masc_domain.Auth Masc_domain.Auth_error.SameOriginBlocked) -> ()
   | Error error ->
     failf
       "cross-origin browser registration returned the wrong typed error: %s"
       (Masc_domain.masc_error_to_string error)
   | Ok () ->
     fail "cross-origin browser registration was admitted before allocation")
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
    ; client_verification = Auth_oauth.Registered_client
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
                ~fetch_client_metadata:no_document
                ~body
            with
            | Ok (Server_oauth_service.Authorization_redirect location) ->
              let callback = Uri.of_string location in
              check (option string) "denial error" (Some "access_denied")
                (Uri.get_query_param callback "error");
              check (option string) "denial preserves state" (Some "preserved-state")
                (Uri.get_query_param callback "state");
              check (option string) "denial names the issuer (RFC 9207)"
                (Some "http://127.0.0.1:8935")
                (Uri.get_query_param callback "iss")
            | Ok (Server_oauth_service.Authorization_form_error _) ->
              fail "denial rendered a form error instead of redirecting"
            | Error error -> fail (Auth_oauth.show_error error)))))
;;

let test_authorization_approval_redirects_with_issuer () =
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
            let bootstrap_token, _ =
              match Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Worker with
              | Ok created -> created
              | Error error -> fail (Masc_domain.masc_error_to_string error)
            in
            let redirect_uri = "http://127.0.0.1:43133/callback/approve" in
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
                ; "state", [ "approved-state" ]
                ; "code_challenge", [ String.make 43 'a' ]
                ; "code_challenge_method", [ "S256" ]
                ; "bootstrap_token", [ bootstrap_token ]
                ; "decision", [ "authorize" ]
                ]
            in
            match
              Server_oauth_service.authorize_post
                ~base_path
                ~authority:(authority ())
                ~fetch_client_metadata:no_document
                ~body
            with
            | Ok (Server_oauth_service.Authorization_redirect location) ->
              let callback = Uri.of_string location in
              check bool "approval carries a code" true
                (Option.is_some (Uri.get_query_param callback "code"));
              check (option string) "approval preserves state" (Some "approved-state")
                (Uri.get_query_param callback "state");
              check (option string) "approval names the issuer (RFC 9207)"
                (Some (Server_oauth_metadata.issuer (authority ())))
                (Uri.get_query_param callback "iss")
            | Ok (Server_oauth_service.Authorization_form_error { message; _ }) ->
              fail ("approval rendered a form error: " ^ message)
            | Error error -> fail (Auth_oauth.show_error error)))))
;;

let claude_code_url = "https://claude.ai/oauth/claude-code-client-metadata"

(* What https://claude.ai/oauth/claude-code-client-metadata served on
   2026-10-27. *)
let claude_code_document =
  {|{"client_id":"https://claude.ai/oauth/claude-code-client-metadata","client_name":"Claude Code","client_uri":"https://claude.ai","redirect_uris":["http://localhost/callback","http://127.0.0.1/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}|}
;;

let with_oauth_workspace f =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_workspace (fun base_path ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio_guard.enable ();
        Fun.protect
          ~finally:(fun () ->
            Eio_guard.disable ();
            Fs_compat.clear_fs ())
          (fun () -> f base_path))))
;;

let authorize_query ?(extra = []) ~client_id ~redirect_uri ~challenge () =
  Uri.encoded_of_query
    ([ "response_type", [ "code" ]
     ; "client_id", [ client_id ]
     ; "redirect_uri", [ redirect_uri ]
     ; "resource", [ "http://127.0.0.1:8935/mcp" ]
     ; "scope", [ "mcp:tools" ]
     ; "state", [ "cimd-state" ]
     ; "code_challenge", [ challenge ]
     ; "code_challenge_method", [ "S256" ]
     ]
     @ extra)
;;

let serving document =
  let fetched = ref [] in
  let fetch url =
    fetched := (url : Auth_oauth_client_metadata.document_url :> string) :: !fetched;
    Ok document
  in
  fetched, fetch
;;

let test_document_client_signs_in () =
  with_oauth_workspace (fun base_path ->
    let bootstrap_token, bootstrap_credential =
      match Auth.create_token base_path ~agent_name:"claude" ~role:Masc_domain.Worker with
      | Ok created -> created
      | Error error -> fail (Masc_domain.masc_error_to_string error)
    in
    let verifier = String.make 43 'v' in
    let challenge = Auth_oauth.pkce_s256 verifier in
    let redirect_uri = "http://localhost:3118/callback" in
    let fetched, fetch_client_metadata = serving claude_code_document in
    let target =
      "/oauth/authorize?"
      ^ authorize_query ~client_id:claude_code_url ~redirect_uri ~challenge ()
    in
    (match
       Server_oauth_service.authorize_get ~base_path ~authority:(authority ()) ~target
     with
     | Error error -> fail (Auth_oauth.show_error error)
     | Ok request ->
       check (option string) "the form claims no name" None request.client_name;
       let html = Server_oauth_service.render_authorization_form request in
       check bool "consent names the document's site" true
         (contains html "named by a document at <code>claude.ai</code>");
       (match
          Auth_oauth.issue_authorization_code
            ~base_path
            ~request
            ~bootstrap_credential:bootstrap_credential
        with
        | Error (Auth_oauth.Invalid_request _) -> ()
        | Error error -> fail ("unexpected refusal: " ^ Auth_oauth.show_error error)
        | Ok _ -> fail "a code was issued for a document nobody checked"));
    check (list string) "the form fetched nothing" [] !fetched;
    let body =
      authorize_query
        ~client_id:claude_code_url
        ~redirect_uri
        ~challenge
        ~extra:[ "bootstrap_token", [ bootstrap_token ]; "decision", [ "authorize" ] ]
        ()
    in
    let location =
      match
        Server_oauth_service.authorize_post
          ~base_path
          ~authority:(authority ())
          ~fetch_client_metadata
          ~body
      with
      | Ok (Server_oauth_service.Authorization_redirect location) -> location
      | Ok (Server_oauth_service.Authorization_form_error { message; _ }) -> fail message
      | Error error -> fail (Auth_oauth.show_error error)
    in
    check (list string) "the approval fetched the client_id URL" [ claude_code_url ] !fetched;
    let callback = Uri.of_string location in
    check (option int) "callback keeps the requested port" (Some 3118) (Uri.port callback);
    let code =
      match Uri.get_query_param callback "code" with
      | Some code -> code
      | None -> fail "approval carried no code"
    in
    match
      Auth_oauth.exchange_authorization_code
        ~base_path
        ~expected_resource:"http://127.0.0.1:8935/mcp"
        ~code
        ~client_id:claude_code_url
        ~redirect_uri
        ~resource:(Some "http://127.0.0.1:8935/mcp")
        ~code_verifier:verifier
    with
    | Ok pair -> check string "bearer pair" "Bearer" pair.token_type
    | Error error -> fail (Auth_oauth.show_error error))
;;

let test_document_client_refusals () =
  with_oauth_workspace (fun base_path ->
    let challenge = String.make 43 'a' in
    let refused ~label ~fetch_client_metadata ~redirect_uri =
      let body =
        authorize_query
          ~client_id:claude_code_url
          ~redirect_uri
          ~challenge
          ~extra:[ "decision", [ "deny" ] ]
          ()
      in
      match
        Server_oauth_service.authorize_post
          ~base_path
          ~authority:(authority ())
          ~fetch_client_metadata
          ~body
      with
      | Error _ -> ()
      | Ok _ -> fail (label ^ " was accepted")
    in
    let _, serve_claude = serving claude_code_document in
    refused ~label:"unreachable document" ~fetch_client_metadata:no_document
      ~redirect_uri:"http://localhost:3118/callback";
    refused ~label:"unlisted path" ~fetch_client_metadata:serve_claude
      ~redirect_uri:"http://localhost:3118/other";
    let listing_a_web_redirect =
      {|{"client_id":"https://claude.ai/oauth/claude-code-client-metadata","client_name":"Claude Code","redirect_uris":["https://attacker.example/cb"]}|}
    in
    let _, serve_web = serving listing_a_web_redirect in
    refused ~label:"a listed redirect off this computer" ~fetch_client_metadata:serve_web
      ~redirect_uri:"https://attacker.example/cb";
    let _, serve_other =
      serving
        {|{"client_id":"https://other.example/meta.json","client_name":"Other","redirect_uris":["http://localhost/callback"]}|}
    in
    refused ~label:"a document naming another client_id" ~fetch_client_metadata:serve_other
      ~redirect_uri:"http://localhost:3118/callback")
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
        ; test_case "listener scope survives wire projection" `Quick
            test_listener_scope_survives_wire_projection
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
            "authorization approval redirects with issuer"
            `Quick
            test_authorization_approval_redirects_with_issuer
        ; test_case "document client signs in" `Quick test_document_client_signs_in
        ; test_case "document client refusals" `Quick test_document_client_refusals
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
