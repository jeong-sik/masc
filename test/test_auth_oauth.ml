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
                ~scope:None
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
                    ~scope:None
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
    "omitted authorization scope defaults to tools"
    true
    (match Auth_oauth.parse_scopes None with
     | Ok [ Auth_oauth.Mcp_tools ] -> true
     | Ok _ | Error _ -> false);
  check
    bool
    "explicitly empty authorization scope is invalid"
    true
    (match Auth_oauth.parse_scopes (Some "   ") with
     | Error Auth_oauth.Invalid_scope -> true
     | Ok _ | Error _ -> false);
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
                    ~scope:None
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
               | Ok _ | Error _ -> false)))))
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

let test_registration_rejects_distinct_client_at_capacity () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_env "MASC_OAUTH_MAX_CLIENTS" "1" (fun () ->
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
                  "a distinct registration is rejected at capacity"
                  true
                  (match
                     Auth_oauth.register_client
                       ~base_path
                       ~client_name:(Some "Codex replacement")
                       ~redirect_uris:[ "http://127.0.0.1:43128/callback/second" ]
                   with
                   | Error Auth_oauth.Temporarily_unavailable -> true
                   | Ok _ | Error _ -> false);
                check
                  bool
                  "capacity pressure preserves the existing registration"
                  true
                  (Auth_oauth.find_client ~base_path ~client_id:first.client_id
                   |> oauth_ok
                   |> Option.is_some);
                check
                  string
                  "an exact retry remains admitted at capacity"
                  first.client_id
                  (let retry =
                     Auth_oauth.register_client
                       ~base_path
                       ~client_name:(Some "Codex")
                       ~redirect_uris:[ "http://127.0.0.1:43127/callback/first" ]
                     |> oauth_ok
                   in
                   retry.client_id))))))
;;

let test_registration_preserves_live_client_at_capacity () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_env "MASC_OAUTH_MAX_CLIENTS" "1" (fun () ->
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
                  ~agent_name:"capacity-codex"
                  ~role:Masc_domain.Worker
                |> auth_ok
              in
              let client, _ =
                issue_pair
                  ~base_path
                  ~bootstrap_credential
                  ~redirect_uri:"http://127.0.0.1:43129/callback/live"
                  ~resource:"http://127.0.0.1:8935/mcp"
                  ~scope:"mcp:tools"
              in
              check
                bool
                "capacity cannot evict a client with a live token family"
                true
                (match
                   Auth_oauth.register_client
                     ~base_path
                     ~client_name:(Some "Blocked client")
                     ~redirect_uris:[ "http://127.0.0.1:43130/callback/blocked" ]
                 with
                 | Error Auth_oauth.Temporarily_unavailable -> true
                 | Ok _ | Error _ -> false);
              check
                bool
                "the live client remains registered"
                true
                (Auth_oauth.find_client ~base_path ~client_id:client.client_id
                 |> oauth_ok
                 |> Option.is_some))))))
;;

let test_refresh_scope_can_reduce_but_not_expand () =
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
              Auth.create_token base_path ~agent_name:"scope-codex" ~role:Masc_domain.Admin
              |> auth_ok
            in
            let resource = "http://127.0.0.1:8935/mcp" in
            let admin_client, admin_pair =
              issue_pair
                ~base_path
                ~bootstrap_credential
                ~redirect_uri:"http://127.0.0.1:43131/callback/admin-only"
                ~resource
                ~scope:"mcp:admin"
            in
            check string "admin response includes its tools implication"
              "mcp:tools mcp:admin" admin_pair.scope;
            check
              bool
              "an explicitly empty refresh scope is invalid"
              true
              (match
                 Auth_oauth.rotate_refresh_token
                   ~base_path
                   ~expected_resource:resource
                   ~refresh_token:admin_pair.refresh_token
                   ~client_id:admin_client.client_id
                   ~scope:(Some "   ")
                   ~resource:(Some resource)
               with
               | Error Auth_oauth.Invalid_scope -> true
               | Ok _ | Error _ -> false);
            let worker_from_admin =
              Auth_oauth.rotate_refresh_token
                ~base_path
                ~expected_resource:resource
                ~refresh_token:admin_pair.refresh_token
                ~client_id:admin_client.client_id
                ~scope:(Some "mcp:tools")
                ~resource:(Some resource)
              |> oauth_ok
            in
            check string "admin family can downscope to tools"
              "mcp:tools" worker_from_admin.scope;
            let client, admin_pair =
              issue_pair
                ~base_path
                ~bootstrap_credential
                ~redirect_uri:"http://127.0.0.1:43131/callback/scope"
                ~resource
                ~scope:"mcp:tools mcp:admin"
            in
            let worker_pair =
              Auth_oauth.rotate_refresh_token
                ~base_path
                ~expected_resource:resource
                ~refresh_token:admin_pair.refresh_token
                ~client_id:client.client_id
                ~scope:(Some "mcp:tools")
                ~resource:(Some resource)
              |> oauth_ok
            in
            check string "refresh response reports reduced scope" "mcp:tools" worker_pair.scope;
            let credential =
              Auth_oauth.with_expected_resource resource (fun () ->
                Auth.find_credential_by_token base_path ~token:worker_pair.access_token)
              |> auth_ok
            in
            check bool "refresh reduction lowers the effective role" true
              (Masc_domain.Worker = credential.role);
            check
              bool
              "a reduced family cannot expand back to admin"
              true
              (match
                 Auth_oauth.rotate_refresh_token
                   ~base_path
                   ~expected_resource:resource
                   ~refresh_token:worker_pair.refresh_token
                   ~client_id:client.client_id
                   ~scope:(Some "mcp:admin")
                   ~resource:(Some resource)
               with
               | Error Auth_oauth.Invalid_scope -> true
               | Ok _ | Error _ -> false)))))
;;

let test_stored_admin_scope_requires_canonical_tools_closure () =
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
              Auth.create_token
                base_path
                ~agent_name:"noncanonical-scope-codex"
                ~role:Masc_domain.Admin
              |> auth_ok
            in
            let resource = "http://127.0.0.1:8935/mcp" in
            let client, pair =
              issue_pair
                ~base_path
                ~bootstrap_credential
                ~redirect_uri:"http://127.0.0.1:43132/callback/noncanonical"
                ~resource
                ~scope:"mcp:admin"
            in
            let families_dir =
              Filename.concat base_path ".masc/auth/oauth/families"
            in
            let family_path =
              Filename.concat families_dir (Sys.readdir families_dir).(0)
            in
            let family_json =
              family_path |> Fs_compat.load_file |> Yojson.Safe.from_string
            in
            let noncanonical =
              match family_json with
              | `Assoc fields ->
                `Assoc
                  (("scopes", `List [ `String "mcp:admin" ])
                   :: List.remove_assoc "scopes" fields)
              | _ -> fail "family store record must be an object"
            in
            (match
               Fs_compat.save_file_atomic
                 family_path
                 (Yojson.Safe.pretty_to_string noncanonical)
             with
             | Ok () -> ()
             | Error message -> fail message);
            check
              bool
              "non-canonical durable admin scope fails closed"
              true
              (Result.is_error
                 (Auth_oauth.rotate_refresh_token
                    ~base_path
                    ~expected_resource:resource
                    ~refresh_token:pair.refresh_token
                    ~client_id:client.client_id
                    ~scope:None
                    ~resource:(Some resource)))))))
;;

let test_rotation_keeps_one_current_access_record () =
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
              let rec rotate remaining pair =
                if remaining = 0
                then pair
                else
                  Auth_oauth.rotate_refresh_token
                    ~base_path
                    ~expected_resource:resource
                    ~refresh_token:pair.Auth_oauth.refresh_token
                    ~client_id:client.client_id
                    ~scope:None
                    ~resource:(Some resource)
                  |> oauth_ok
                  |> rotate (remaining - 1)
              in
              ignore (rotate 8 first);
              let oauth_store = Filename.concat base_path ".masc/auth/oauth" in
              let count dir =
                Sys.readdir (Filename.concat oauth_store dir)
                |> Array.to_list
                |> List.filter (fun path -> Filename.check_suffix path ".json")
                |> List.length
              in
              check int "rotation retains one access record" 1 (count "access_tokens");
              check int "rotation retains one family SSOT" 1 (count "families");
              let family_file =
                (Sys.readdir (Filename.concat oauth_store "families")).(0)
              in
              let family_json =
                Filename.concat (Filename.concat oauth_store "families") family_file
                |> Fs_compat.load_file
                |> Yojson.Safe.from_string
              in
              let family_fields = Yojson.Safe.Util.to_assoc family_json in
              let stored_bootstrap_hash =
                Yojson.Safe.Util.member "bootstrap_token_hash" family_json
                |> Yojson.Safe.Util.to_string
              in
              check
                bool
                "family never persists the raw bootstrap bearer"
                true
                (not
                   (String.equal
                      stored_bootstrap_hash
                      bootstrap_credential.token));
              List.iter
                (fun field ->
                  check
                    bool
                    (field ^ " is absent from the current store contract")
                    false
                    (List.mem_assoc field family_fields))
                [ "generation"; "updated_at_unix" ];
              check
                bool
                "refresh tokens have no per-generation record directory"
                false
                (Sys.file_exists (Filename.concat oauth_store "refresh_tokens"))))))
;;

let test_unbound_resource_context_fails_closed_without_raising () =
  with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
    with_workspace (fun base_path ->
      let oauth_store = Filename.concat base_path ".masc/auth/oauth" in
      match Auth_oauth.find_access_credential ~base_path ~token:"not-an-oauth-token" with
      | Ok None ->
        check bool "unknown static token does not initialize OAuth storage" false
          (Sys.file_exists oauth_store)
      | Ok (Some _) -> fail "an unknown token resolved without a resource context"
      | Error error -> fail (Masc_domain.show_masc_error error)))
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
            "registration rejects distinct client at capacity"
            `Quick
            test_registration_rejects_distinct_client_at_capacity
        ; test_case
            "registration preserves live client at capacity"
            `Quick
            test_registration_preserves_live_client_at_capacity
        ; test_case
            "refresh scope can reduce but not expand"
            `Quick
            test_refresh_scope_can_reduce_but_not_expand
        ; test_case
            "stored admin scope requires canonical tools closure"
            `Quick
            test_stored_admin_scope_requires_canonical_tools_closure
        ; test_case
            "rotation keeps one current access record"
            `Quick
            test_rotation_keeps_one_current_access_record
        ; test_case
            "unbound resource context fails closed without raising"
            `Quick
            test_unbound_resource_context_fails_closed_without_raising
        ] )
    ]
;;
