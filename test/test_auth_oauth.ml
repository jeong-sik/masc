let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest

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
      (Printf.sprintf "masc-oauth-%d-%Ld" (Unix.getpid ()) (Int64.bits_of_float (Unix.gettimeofday ())))
  in
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let get_ok show_error = function
  | Ok value -> value
  | Error error -> fail (show_error error)
;;

let oauth_ok result = get_ok Auth_oauth.show_error result
let auth_ok result = get_ok Masc_domain.masc_error_to_string result

let authorization_request
    ?(scope = "mcp:tools")
    ~base_path
    ~client_id
    ~redirect_uri
    ~resource
    ~challenge
    ()
  =
  Auth_oauth.validate_authorization_request
    ~base_path
    ~expected_resource:resource
    ~response_type:(Some "code")
    ~client_id:(Some client_id)
    ~redirect_uri:(Some redirect_uri)
    ~resource:(Some resource)
    ~scope:(Some scope)
    ~state:(Some "codex-state")
    ~code_challenge:(Some challenge)
    ~code_challenge_method:(Some "S256")
  |> oauth_ok
;;

let issue_pair
    ~base_path
    ~(bootstrap_credential : Masc_domain.agent_credential)
    ~redirect_uri
    ~resource
    ~scope
  =
  let client =
    Auth_oauth.register_client
      ~base_path
      ~client_name:(Some "Codex")
      ~redirect_uris:[ redirect_uri ]
    |> oauth_ok
  in
  let verifier = String.make 43 'v' in
  let request =
    authorization_request
      ~scope
      ~base_path
      ~client_id:client.client_id
      ~redirect_uri
      ~resource
      ~challenge:(Auth_oauth.pkce_s256 verifier)
      ()
  in
  let code =
    Auth_oauth.issue_authorization_code ~base_path ~request ~bootstrap_credential
    |> oauth_ok
  in
  let pair =
    Auth_oauth.exchange_authorization_code
      ~base_path
      ~expected_resource:resource
      ~code
      ~client_id:client.client_id
      ~redirect_uri
      ~resource:(Some resource)
      ~code_verifier:verifier
    |> oauth_ok
  in
  client, pair
;;

let test_pkce_rfc7636_vector () =
  check
    string
    "RFC 7636 Appendix B S256"
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    (Auth_oauth.pkce_s256 "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
;;

let test_dual_auth_code_and_refresh_lifecycle () =
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
            let static_token, static_credential =
              Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Admin
              |> auth_ok
            in
            let redirect_uri = "http://127.0.0.1:43123/callback/codexoauth123" in
            let resource = "http://127.0.0.1:8935/mcp" in
            let client =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris:[ redirect_uri ]
              |> oauth_ok
            in
            let client_file =
              Filename.concat
                base_path
                (".masc/auth/oauth/clients/"
                 ^ Digestif.SHA256.(digest_string client.client_id |> to_hex)
                 ^ ".json")
            in
            check
              int
              "OAuth records are private at creation"
              0o600
              ((Unix.stat client_file).st_perm land 0o777);
            let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" in
            let request =
              authorization_request
                ~base_path
                ~client_id:client.client_id
                ~redirect_uri
                ~resource
                ~challenge:(Auth_oauth.pkce_s256 verifier)
                ()
            in
            let code =
              Auth_oauth.issue_authorization_code
                ~base_path
                ~request
                ~bootstrap_credential:static_credential
              |> oauth_ok
            in
            let wrong_verifier = String.make 43 'a' in
            check
              bool
              "wrong verifier rejected without consuming code"
              true
              (Result.is_error
                 (Auth_oauth.exchange_authorization_code
                    ~base_path
                    ~expected_resource:resource
                    ~code
                    ~client_id:client.client_id
                    ~redirect_uri
                    ~resource:(Some resource)
                    ~code_verifier:wrong_verifier));
            let first_pair =
              Auth_oauth.exchange_authorization_code
                ~base_path
                ~expected_resource:resource
                ~code
                ~client_id:client.client_id
                ~redirect_uri
                ~resource:(Some resource)
                ~code_verifier:verifier
              |> oauth_ok
            in
            check
              bool
              "authorization code is one-time"
              true
              (Result.is_error
                 (Auth_oauth.exchange_authorization_code
                    ~base_path
                    ~expected_resource:resource
                    ~code
                    ~client_id:client.client_id
                    ~redirect_uri
                    ~resource:(Some resource)
                    ~code_verifier:verifier));
            let oauth_credential =
              Auth_oauth.with_expected_resource resource (fun () ->
                Auth.find_credential_by_token
                  base_path
                  ~token:first_pair.access_token)
              |> auth_ok
            in
            check string "OAuth actor" "codex" oauth_credential.agent_name;
            check
              bool
              "scope reduces admin bootstrap to worker"
              true
              (Masc_domain.Worker = oauth_credential.role);
            ignore
              (Auth_oauth.with_expected_resource resource (fun () ->
                 Auth.verify_token
                   base_path
                   ~agent_name:"codex"
                   ~token:first_pair.access_token)
               |> auth_ok);
            check
              bool
              "OAuth actor mismatch is rejected"
              true
              (Result.is_error
                 (Auth_oauth.with_expected_resource resource (fun () ->
                    Auth.verify_token
                      base_path
                      ~agent_name:"another-agent"
                      ~token:first_pair.access_token)));
            ignore (Auth.verify_token base_path ~agent_name:"codex" ~token:static_token |> auth_ok);
            let second_pair =
              Auth_oauth.rotate_refresh_token
                ~base_path
                ~expected_resource:resource
                ~refresh_token:first_pair.refresh_token
                ~client_id:client.client_id
                ~resource:None
              |> oauth_ok
            in
            check
              bool
              "rotation revokes previous access token"
              true
              (Result.is_error
                 (Auth_oauth.with_expected_resource resource (fun () ->
                    Auth.find_credential_by_token
                      base_path
                      ~token:first_pair.access_token)));
            ignore
              (Auth_oauth.with_expected_resource resource (fun () ->
                 Auth.find_credential_by_token
                   base_path
                   ~token:second_pair.access_token)
               |> auth_ok);
            check
              bool
              "access token is bound to the exact admitted MCP resource"
              true
              (Result.is_error
                 (Auth_oauth.with_expected_resource
                    "http://localhost:8935/mcp"
                    (fun () ->
                      Auth.find_credential_by_token
                        base_path
                        ~token:second_pair.access_token)));
            check
              bool
              "refresh replay revokes the token family"
              true
              (Result.is_error
                 (Auth_oauth.rotate_refresh_token
                    ~base_path
                    ~expected_resource:resource
                    ~refresh_token:first_pair.refresh_token
                    ~client_id:client.client_id
                    ~resource:None));
            check
              bool
              "refresh replay invalidates the current access token"
              true
              (Result.is_error
                 (Auth_oauth.with_expected_resource resource (fun () ->
                    Auth.find_credential_by_token
                      base_path
                      ~token:second_pair.access_token)));
            with_env "MASC_OAUTH_ENABLED" "0" (fun () ->
              check
                bool
                "disabling OAuth cuts existing access"
                true
                (Result.is_error
                   (Auth.find_credential_by_token base_path ~token:second_pair.access_token));
              ignore
                (Auth.verify_token base_path ~agent_name:"codex" ~token:static_token
                 |> auth_ok))))))
;;

let test_consumed_code_is_not_restored_after_store_failure () =
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
            let _, bootstrap_credential =
              Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Admin
              |> auth_ok
            in
            let redirect_uri = "http://127.0.0.1:43124/callback/codexoauth456" in
            let resource = "http://127.0.0.1:8935/mcp" in
            let client =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris:[ redirect_uri ]
              |> oauth_ok
            in
            let verifier = String.make 43 'b' in
            let request =
              authorization_request
                ~base_path
                ~client_id:client.client_id
                ~redirect_uri
                ~resource
                ~challenge:(Auth_oauth.pkce_s256 verifier)
                ()
            in
            let code =
              Auth_oauth.issue_authorization_code
                ~base_path
                ~request
                ~bootstrap_credential
              |> oauth_ok
            in
            let access_tokens_dir =
              Filename.concat base_path ".masc/auth/oauth/access_tokens"
            in
            let first_exchange =
              Unix.chmod access_tokens_dir 0o500;
              Fun.protect
                ~finally:(fun () -> Unix.chmod access_tokens_dir 0o700)
                (fun () ->
                  Auth_oauth.exchange_authorization_code
                    ~base_path
                    ~expected_resource:resource
                    ~code
                    ~client_id:client.client_id
                    ~redirect_uri
                    ~resource:(Some resource)
                    ~code_verifier:verifier)
            in
            check bool "token mint fails when its store is unwritable" true (Result.is_error first_exchange);
            check
              bool
              "a claimed code remains consumed after mint failure"
              true
              (Result.is_error
                 (Auth_oauth.exchange_authorization_code
                    ~base_path
                    ~expected_resource:resource
                    ~code
                    ~client_id:client.client_id
                    ~redirect_uri
                    ~resource:(Some resource)
                    ~code_verifier:verifier))))))
;;

let test_scope_cannot_escalate_role () =
  check
    bool
    "worker cannot obtain admin scope"
    true
    (Result.is_error
       (Auth_oauth.effective_role
          ~bootstrap_role:Masc_domain.Worker
          [ Auth_oauth.Mcp_admin ]));
  check
    bool
    "admin scope preserves an admin bootstrap"
    true
    (match
       Auth_oauth.effective_role
         ~bootstrap_role:Masc_domain.Admin
         [ Auth_oauth.Mcp_admin ]
     with
     | Ok Masc_domain.Admin -> true
     | Ok Masc_domain.Worker | Error _ -> false)
;;

let test_live_bootstrap_credential_remains_authoritative () =
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
            let resource = "http://127.0.0.1:8935/mcp" in
            let static_token, admin_credential =
              Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Admin
              |> auth_ok
            in
            let admin_client, admin_pair =
              issue_pair
                ~base_path
                ~bootstrap_credential:admin_credential
                ~redirect_uri:"http://127.0.0.1:43125/callback/admin"
                ~resource
                ~scope:"mcp:admin"
            in
            let admin_access () =
              Auth_oauth.with_expected_resource resource (fun () ->
                Auth.find_credential_by_token base_path ~token:admin_pair.access_token)
            in
            check bool "admin OAuth access starts valid" true (Result.is_ok (admin_access ()));
            ignore
              (Auth.save_raw_token_credential_without_expiry
                 base_path
                 ~agent_name:"codex"
                 ~role:Masc_domain.Worker
                 ~raw_token:static_token
               |> auth_ok);
            check
              bool
              "admin OAuth access is revoked after live role demotion"
              true
              (Result.is_error (admin_access ()));
            check
              bool
              "admin refresh is revoked after live role demotion"
              true
              (Result.is_error
                 (Auth_oauth.rotate_refresh_token
                    ~base_path
                    ~expected_resource:resource
                    ~refresh_token:admin_pair.refresh_token
                    ~client_id:admin_client.client_id
                    ~resource:(Some resource)));
            let worker_token, worker_credential =
              Auth.create_token base_path ~agent_name:"codex" ~role:Masc_domain.Worker
              |> auth_ok
            in
            ignore worker_token;
            let _, worker_pair =
              issue_pair
                ~base_path
                ~bootstrap_credential:worker_credential
                ~redirect_uri:"http://127.0.0.1:43126/callback/worker"
                ~resource
                ~scope:"mcp:tools"
            in
            Auth.delete_credential base_path "codex";
            check
              bool
              "OAuth access is revoked after live credential deletion"
              true
              (Result.is_error
                 (Auth_oauth.with_expected_resource resource (fun () ->
                    Auth.find_credential_by_token base_path ~token:worker_pair.access_token)))))))
;;

let test_code_exchange_rechecks_live_bootstrap () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_env "MASC_OAUTH_CLIENT_REGISTRATION_TTL_SEC" "1" (fun () ->
      with_workspace (fun base_path ->
        Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Eio_guard.enable ();
        Fun.protect
          ~finally:(fun () ->
            Eio_guard.disable ();
            Fs_compat.clear_fs ())
          (fun () ->
            let _, bootstrap_credential =
              Auth.create_token
                base_path
                ~agent_name:"revoked-before-exchange"
                ~role:Masc_domain.Worker
              |> auth_ok
            in
            let redirect_uri = "http://127.0.0.1:43130/callback/revoked" in
            let resource = "http://127.0.0.1:8935/mcp" in
            let client =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris:[ redirect_uri ]
              |> oauth_ok
            in
            let verifier = String.make 43 'r' in
            let request =
              authorization_request
                ~base_path
                ~client_id:client.client_id
                ~redirect_uri
                ~resource
                ~challenge:(Auth_oauth.pkce_s256 verifier)
                ()
            in
            let code =
              Auth_oauth.issue_authorization_code
                ~base_path
                ~request
                ~bootstrap_credential
              |> oauth_ok
            in
            Eio.Time.sleep (Eio.Stdenv.clock env) 1.1;
            check
              bool
              "approved client survives registration lease expiry"
              true
              (Auth_oauth.find_client ~base_path ~client_id:client.client_id
               |> oauth_ok
               |> Option.is_some);
            Auth.delete_credential base_path "revoked-before-exchange";
            check
              bool
              "code exchange fails after bootstrap revocation"
              true
              (match
                 Auth_oauth.exchange_authorization_code
                   ~base_path
                   ~expected_resource:resource
                   ~code
                   ~client_id:client.client_id
                   ~redirect_uri
                   ~resource:(Some resource)
                   ~code_verifier:verifier
               with
               | Error Auth_oauth.Invalid_grant -> true
               | Ok _ | Error _ -> false))))))
;;

let test_registration_rejects_non_loopback_redirect () =
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
            check
              bool
              "public redirect URI rejected"
              true
              (Result.is_error
                 (Auth_oauth.register_client
                    ~base_path
                    ~client_name:(Some "Codex")
                    ~redirect_uris:[ "https://example.com/callback" ]));
            let redirect_uris =
              [ "http://127.0.0.1:43123/callback"; "http://localhost:43123/callback" ]
            in
            let first =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris
              |> oauth_ok
            in
            let retry =
              Auth_oauth.register_client
                ~base_path
                ~client_name:(Some "Codex")
                ~redirect_uris:(List.rev redirect_uris)
              |> oauth_ok
            in
            check
              string
              "exact registration retry reuses the existing client"
              first.client_id
              retry.client_id))))
;;

let test_registration_capacity_is_recoverable () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_env "MASC_OAUTH_MAX_CLIENTS" "1" (fun () ->
      with_env "MASC_OAUTH_CLIENT_REGISTRATION_TTL_SEC" "1" (fun () ->
        with_workspace (fun base_path ->
          Eio_main.run (fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            Eio_guard.enable ();
            Fun.protect
              ~finally:(fun () ->
                Eio_guard.disable ();
                Fs_compat.clear_fs ())
              (fun () ->
                let first =
                  Auth_oauth.register_client
                    ~base_path
                    ~client_name:(Some "Codex")
                    ~redirect_uris:[ "http://127.0.0.1:43127/callback/first" ]
                  |> oauth_ok
                in
                let repeated =
                  Auth_oauth.register_client
                    ~base_path
                    ~client_name:(Some "Codex")
                    ~redirect_uris:[ "http://127.0.0.1:43127/callback/first" ]
                  |> oauth_ok
                in
                check
                  string
                  "exact DCR retry is idempotent"
                  first.client_id
                  repeated.client_id;
                check
                  bool
                  "an active client is not evicted at capacity"
                  true
                  (match
                     Auth_oauth.register_client
                       ~base_path
                       ~client_name:(Some "Codex replacement")
                       ~redirect_uris:[ "http://127.0.0.1:43128/callback/second" ]
                   with
                   | Error Auth_oauth.Temporarily_unavailable -> true
                   | Ok _ | Error _ -> false);
                Eio.Time.sleep (Eio.Stdenv.clock env) 1.1;
                let replacement =
                  Auth_oauth.register_client
                    ~base_path
                    ~client_name:(Some "Codex replacement")
                    ~redirect_uris:[ "http://127.0.0.1:43128/callback/second" ]
                  |> oauth_ok
                in
                check
                  bool
                  "expired client is reclaimed at capacity"
                  true
                  (Auth_oauth.find_client ~base_path ~client_id:first.client_id
                   |> oauth_ok
                   |> Option.is_none);
                check
                  bool
                  "new registration succeeds after expiry recovery"
                  true
                  (Auth_oauth.find_client ~base_path ~client_id:replacement.client_id
                   |> oauth_ok
                   |> Option.is_some)))))))
;;

let test_durable_token_store_is_bounded () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_env "MASC_OAUTH_MAX_TOKEN_RECORDS" "4" (fun () ->
      with_workspace (fun base_path ->
        Eio_main.run (fun env ->
          Fs_compat.set_fs (Eio.Stdenv.fs env);
          Eio_guard.enable ();
          Fun.protect
            ~finally:(fun () ->
              Eio_guard.disable ();
              Fs_compat.clear_fs ())
            (fun () ->
              let _, bootstrap_credential =
                Auth.create_token
                  base_path
                  ~agent_name:"bounded-codex"
                  ~role:Masc_domain.Worker
                |> auth_ok
              in
              let resource = "http://127.0.0.1:8935/mcp" in
              let client, first =
                issue_pair
                  ~base_path
                  ~bootstrap_credential
                  ~redirect_uri:"http://127.0.0.1:43129/callback/bounded"
                  ~resource
                  ~scope:"mcp:tools"
              in
              let second =
                Auth_oauth.rotate_refresh_token
                  ~base_path
                  ~expected_resource:resource
                  ~refresh_token:first.refresh_token
                  ~client_id:client.client_id
                  ~resource:(Some resource)
                |> oauth_ok
              in
              check
                bool
                "capacity rejects further durable growth"
                true
                (match
                   Auth_oauth.rotate_refresh_token
                     ~base_path
                     ~expected_resource:resource
                     ~refresh_token:second.refresh_token
                     ~client_id:client.client_id
                     ~resource:(Some resource)
                 with
                 | Error Auth_oauth.Temporarily_unavailable -> true
                 | Ok _ | Error _ -> false);
              let oauth_store = Filename.concat base_path ".masc/auth/oauth" in
              let count dir =
                Sys.readdir (Filename.concat oauth_store dir)
                |> Array.to_list
                |> List.filter (fun path -> Filename.check_suffix path ".json")
                |> List.length
              in
              check
                bool
                "token record count stays within configured bound"
                true
                (count "access_tokens" + count "refresh_tokens"
                 <= Auth_oauth.max_token_records ()))))))
;;

let () =
  run
    "auth_oauth"
    [ ( "oauth"
      , [ test_case "PKCE RFC vector" `Quick test_pkce_rfc7636_vector
        ; test_case
            "dual auth code and refresh lifecycle"
            `Quick
            test_dual_auth_code_and_refresh_lifecycle
        ; test_case
            "registration loopback restriction"
            `Quick
            test_registration_rejects_non_loopback_redirect
        ; test_case
            "consumed code survives store failure"
            `Quick
            test_consumed_code_is_not_restored_after_store_failure
        ; test_case "scope cannot escalate role" `Quick test_scope_cannot_escalate_role
        ; test_case
            "live bootstrap credential remains authoritative"
            `Quick
            test_live_bootstrap_credential_remains_authoritative
        ; test_case
            "code exchange rechecks live bootstrap"
            `Quick
            test_code_exchange_rechecks_live_bootstrap
        ; test_case
            "registration capacity is recoverable"
            `Quick
            test_registration_capacity_is_recoverable
        ; test_case
            "durable token store is bounded"
            `Quick
            test_durable_token_store_is_bounded
        ] )
    ]
;;
