open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

module Dev_token = Server_routes_http_dashboard_dev_token

let authority_exn raw =
  let request =
    Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "host", raw ])
      `GET
      "/api/v1/dashboard/dev-token"
  in
  let trust_policy =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:"attacker.example"
        ~bind_port:8935
        ~explicit_base_url:None
    with
    | Ok policy -> policy
    | Error error ->
      fail (Server_request_authority.trust_policy_error_to_string error)
  in
  match
    Server_request_authority.classify_http1_request ~trust_policy request
  with
  | Server_request_authority.Single authority -> authority
  | ( Server_request_authority.Missing
    | Server_request_authority.Multiple
    | Server_request_authority.Malformed
    | Server_request_authority.Untrusted ) ->
    failf "expected valid authority %S" raw
;;

let test_non_loopback_error_contract () =
  let error = Dev_token.Non_loopback_request_host "attacker.example" in
  check int "HTTP status" 403 (Httpun.Status.to_code (Dev_token.request_error_status error));
  check
    string
    "typed code"
    "dashboard_dev_token_host_non_loopback"
    (Dev_token.request_error_code error);
  check
    string
    "operator message"
    "dashboard dev-token request Host \"attacker.example\" is not an exact loopback host"
    (Dev_token.request_error_to_string error)
;;

let test_non_loopback_rejection_precedes_token_io () =
  let base_path = Filename.temp_file "masc-dev-token-host-" ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists base_path then Unix.rmdir base_path)
    (fun () ->
      match
        Dev_token.ensure_dashboard_dev_token_for_authority
          ~request_authority:(authority_exn "attacker.example:8935")
          ~base_path
      with
      | Error (Dev_token.Non_loopback_request_host "attacker.example") ->
        check bool "base path remains absent" false (Sys.file_exists base_path)
      | Error error ->
        failf "unexpected error: %s" (Dev_token.request_error_to_string error)
      | Ok _ -> fail "non-loopback authority must not reach token I/O")
;;

let test_read_failure_does_not_mint_admin_credential () =
  let base_path = Filename.temp_file "masc-dev-token-read-" ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let token_path = Dev_token.dashboard_dev_token_path base_path in
      Fs_compat.mkdir_p (Filename.dirname token_path);
      Fs_compat.save_file token_path "stale";
      Dev_token.set_dashboard_dev_token_load_for_testing (fun _ ->
        raise (Sys_error "injected read failure"));
      Fun.protect
        ~finally:Dev_token.reset_dashboard_dev_token_load_for_testing
        (fun () ->
          match Dev_token.ensure_dashboard_dev_token base_path with
          | Error _ ->
              check
                bool
                "read failure creates no credential store"
            false
            (Sys.file_exists (Common.agents_dir_from_base_path ~base_path))
          | Ok _ -> fail "unreadable dev-token path must fail closed"))
;;

let with_temporary_base prefix f =
  let base_path = Filename.temp_file prefix ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let test_new_dashboard_dev_token_is_worker () =
  with_temporary_base "masc-dev-token-worker-" (fun base_path ->
    match Dev_token.ensure_dashboard_dev_token_with_state base_path with
    | Error message -> fail message
    | Ok ensured ->
      check bool
        "new token reports Worker mint"
        true
        (ensured.state = Dev_token.Minted_worker_credential);
      (match Auth.find_credential_by_token base_path ~token:ensured.token with
       | Error error -> fail (Masc_domain.masc_error_to_string error)
       | Ok credential ->
         check string
           "credential owner"
           Auth.dashboard_dev_actor_name
           credential.agent_name;
         check bool "persisted role is Worker" true (credential.role = Masc_domain.Worker);
         check bool
           "effective role is Worker"
           true
           (Auth.effective_credential_role credential = Masc_domain.Worker)))
;;

let test_legacy_dashboard_admin_is_reused_with_worker_authority () =
  with_temporary_base "masc-dev-token-legacy-admin-" (fun base_path ->
    ignore
      (Auth.enable_auth
         base_path
         ~require_token:true
         ~agent_name:"operator");
    match
      Auth.create_token base_path
        ~agent_name:Auth.dashboard_dev_actor_name
        ~role:Masc_domain.Admin
    with
    | Error error -> fail (Masc_domain.masc_error_to_string error)
    | Ok (legacy_token, _credential) ->
      Auth.save_private_text_file
        (Dev_token.dashboard_dev_token_path base_path)
        legacy_token;
      (match Dev_token.ensure_dashboard_dev_token_with_state base_path with
       | Error message -> fail message
       | Ok ensured ->
         check string "legacy raw token is not rotated" legacy_token ensured.token;
         check bool
           "legacy migration state is explicit"
           true
           (ensured.state = Dev_token.Reused_legacy_admin_credential);
         (match
            Auth.verify_token base_path
              ~agent_name:Auth.dashboard_dev_actor_name
              ~token:legacy_token
          with
          | Error error -> fail (Masc_domain.masc_error_to_string error)
          | Ok credential ->
            let authority = Auth.credential_authority credential in
            check bool
              "persisted role remains Admin for audit"
              true
              (authority.persisted_role = Masc_domain.Admin);
            check bool
              "effective role is capped to Worker"
              true
              (authority.effective_role = Masc_domain.Worker);
            check bool
              "authority state records legacy cap"
              true
              (authority.state = Auth.Legacy_dashboard_admin_capped));
         [ Masc_domain.CanAdmin; Masc_domain.CanInit; Masc_domain.CanReset ]
         |> List.iter (fun permission ->
           match
             Auth.check_permission base_path
               ~agent_name:Auth.dashboard_dev_actor_name
               ~token:(Some legacy_token)
               ~permission
           with
           | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
           | Error error ->
             failf
               "legacy dashboard Admin returned the wrong denial for %s: %s"
               (Masc_domain.permission_to_string permission)
               (Masc_domain.masc_error_to_string error)
           | Ok () ->
             failf
               "legacy dashboard Admin retained %s authority"
               (Masc_domain.permission_to_string permission)))
  )
;;

let test_shared_dashboard_token_fails_closed_without_rotation () =
  with_temporary_base "masc-dev-token-shared-" (fun base_path ->
    ignore
      (Auth.enable_auth
         base_path
         ~require_token:true
         ~agent_name:"operator");
    match
      Auth.create_token base_path
        ~agent_name:Auth.dashboard_dev_actor_name
        ~role:Masc_domain.Admin
    with
    | Error error -> fail (Masc_domain.masc_error_to_string error)
    | Ok (shared_token, dashboard_before) ->
      (match
         Auth.save_raw_token_credential base_path
           ~agent_name:"admin"
           ~role:Masc_domain.Admin
           ~raw_token:shared_token
       with
       | Error error -> fail (Masc_domain.masc_error_to_string error)
       | Ok _ -> ());
      Auth.save_private_text_file
        (Dev_token.dashboard_dev_token_path base_path)
        shared_token;
      (match Dev_token.ensure_dashboard_dev_token_with_state base_path with
       | Ok _ -> fail "fresh shared dashboard token must fail closed"
       | Error _ -> ());
      match Auth.load_credential base_path Auth.dashboard_dev_actor_name with
      | None -> fail "dashboard credential disappeared after shared-token rejection"
      | Some dashboard_after ->
        check string
          "dashboard credential was not rotated"
          dashboard_before.token
          dashboard_after.token)
;;

let () =
  run
    "dashboard-dev-token-host-gate"
    [ ( "validated authority policy"
      , [ test_case "non-loopback error contract" `Quick test_non_loopback_error_contract
        ; test_case
            "non-loopback rejected before token I/O"
            `Quick
            test_non_loopback_rejection_precedes_token_io
        ; test_case
            "read failure does not mint admin credential"
            `Quick
            test_read_failure_does_not_mint_admin_credential
        ; test_case
            "new dashboard dev-token is Worker"
            `Quick
            test_new_dashboard_dev_token_is_worker
        ; test_case
            "legacy dashboard Admin is capped without rotation"
            `Quick
            test_legacy_dashboard_admin_is_reused_with_worker_authority
        ; test_case
            "fresh shared dashboard token fails closed without rotation"
            `Quick
            test_shared_dashboard_token_fails_closed_without_rotation
        ] )
    ]
;;
