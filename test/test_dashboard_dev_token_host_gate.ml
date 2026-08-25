let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest

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

let test_read_failure_does_not_mint_credential () =
  let base_path = Filename.temp_file "masc-dev-token-read-" ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let token_path = Dev_token.dashboard_dev_token_path base_path in
      Fs_compat.mkdir_p (Filename.dirname token_path);
      Fs_compat.save_file token_path "stale";
      match
        Dev_token.ensure_dashboard_dev_token
          ~load:(fun _ -> raise (Sys_error "injected read failure"))
          base_path
      with
      | Error _ ->
        check
          bool
          "read failure creates no credential store"
          false
          (Sys.file_exists (Common.agents_dir_from_base_path ~base_path))
      | Ok _ -> fail "unreadable dev-token path must fail closed")
;;

let with_temp_base label f =
  let base_path = Filename.temp_dir label ".workspace" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let create_persisted_dashboard_token base_path role =
  match Auth.create_token base_path ~agent_name:"dashboard" ~role with
  | Error err -> fail (Masc_domain.masc_error_to_string err)
  | Ok (raw, _credential) ->
    Auth.save_private_text_file (Dev_token.dashboard_dev_token_path base_path) raw;
    raw
;;

let test_existing_worker_token_rotates_to_admin () =
  with_temp_base "masc-dev-token-role-" (fun base_path ->
    let worker_raw = create_persisted_dashboard_token base_path Masc_domain.Worker in
    match Dev_token.ensure_dashboard_dev_token base_path with
    | Error error -> fail (Dev_token.token_error_to_string error)
    | Ok token ->
      check bool "worker bearer rotated" true (not (String.equal worker_raw token.raw));
      check string "canonical actor" "dashboard" token.actor;
      check string "declared role" "admin"
        (Masc_domain.agent_role_to_string token.role);
      (match Auth.find_credential_by_token base_path ~token:token.raw with
       | Error err -> fail (Masc_domain.masc_error_to_string err)
       | Ok credential ->
         check string "persisted credential role" "admin"
           (Masc_domain.agent_role_to_string credential.role));
      (match
         Auth.check_permission
           base_path
           ~agent_name:"dashboard"
           ~token:(Some token.raw)
           ~permission:Masc_domain.CanAdmin
       with
       | Ok () -> ()
       | Error err ->
         failf
           "dashboard Admin token denied CanAdmin: %s"
           (Masc_domain.masc_error_to_string err));
      check
        int
        "canonical token mode"
        0o600
        ((Unix.stat (Dev_token.dashboard_dev_token_path base_path)).Unix.st_perm
         land 0o777);
      (match Auth.find_credential_by_token base_path ~token:worker_raw with
       | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
       | Error err ->
         failf
           "old worker token failed with wrong reason: %s"
           (Masc_domain.masc_error_to_string err)
       | Ok _ -> fail "old worker token remains valid after rotation"))
;;

let test_existing_admin_token_is_reused () =
  with_temp_base "masc-dev-token-reuse-" (fun base_path ->
    let admin_raw = create_persisted_dashboard_token base_path Masc_domain.Admin in
    match Dev_token.ensure_dashboard_dev_token base_path with
    | Error error -> fail (Dev_token.token_error_to_string error)
    | Ok token -> check string "admin bearer reused" admin_raw token.raw)
;;

let test_invalid_pending_token_fails_closed () =
  with_temp_base "masc-dev-token-invalid-pending-" (fun base_path ->
    let pending_path = Dev_token.dashboard_dev_token_pending_path base_path in
    Fs_compat.mkdir_p (Filename.dirname pending_path);
    Auth.save_private_text_file pending_path "not-a-generated-token";
    match Dev_token.ensure_dashboard_dev_token base_path with
    | Error (Dev_token.Rotation_journal_invalid { path }) ->
      check string "typed invalid journal path" pending_path path;
      check int "no credential minted" 0 (List.length (Auth.list_credentials base_path))
    | Error error ->
      failf "unexpected pending-token error: %s" (Dev_token.token_error_to_string error)
    | Ok _ -> fail "invalid pending token must not mint a replacement")
;;

let test_rotation_write_failure_reuses_pending_token () =
  with_temp_base "masc-dev-token-pending-" (fun base_path ->
    let stale_raw = create_persisted_dashboard_token base_path Masc_domain.Worker in
    let token_path = Dev_token.dashboard_dev_token_path base_path in
    let write path raw =
      if String.equal path token_path
      then Error "injected canonical token write failure"
      else (
        Auth.save_private_text_file path raw;
        Ok ())
    in
    (match Dev_token.ensure_dashboard_dev_token ~write base_path with
     | Error (Dev_token.Token_file_write_failed _) -> ()
     | Error error ->
       failf "unexpected rotation error: %s" (Dev_token.token_error_to_string error)
     | Ok _ -> fail "injected canonical write failure succeeded");
    let pending_path = Dev_token.dashboard_dev_token_pending_path base_path in
    check bool "pending token retained" true (Sys.file_exists pending_path);
    let pending_raw = String.trim (Fs_compat.load_file pending_path) in
    (match Auth.find_credential_by_token base_path ~token:stale_raw with
     | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
     | Error err ->
       failf
         "old worker token failed with wrong reason: %s"
         (Masc_domain.masc_error_to_string err)
     | Ok _ -> fail "old worker token reactivated after partial rotation");
    match Dev_token.ensure_dashboard_dev_token base_path with
    | Error error -> fail (Dev_token.token_error_to_string error)
    | Ok token ->
      check string "exact pending token published" pending_raw token.raw;
      check bool "pending token cleared" false (Sys.file_exists pending_path))
;;

let test_fresh_issuance_grants_admin () =
  with_temp_base "masc-dev-token-fresh-" (fun base_path ->
    match Dev_token.ensure_dashboard_dev_token base_path with
    | Error error -> fail (Dev_token.token_error_to_string error)
    | Ok token ->
      check string "canonical actor" "dashboard" token.actor;
      check string "declared role" "admin"
        (Masc_domain.agent_role_to_string token.role);
      (match
         Auth.check_permission
           base_path
           ~agent_name:"dashboard"
           ~token:(Some token.raw)
           ~permission:Masc_domain.CanAdmin
       with
       | Ok () -> ()
       | Error err ->
         failf
           "fresh dev token denied CanAdmin: %s"
           (Masc_domain.masc_error_to_string err));
      (match Dev_token.ensure_dashboard_dev_token base_path with
       | Error error -> fail (Dev_token.token_error_to_string error)
       | Ok reissued -> check string "admin bearer reused" token.raw reissued.raw))
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
            "read failure does not mint credential"
            `Quick
            test_read_failure_does_not_mint_credential
        ; test_case
            "existing worker token rotates to admin"
            `Quick
            test_existing_worker_token_rotates_to_admin
        ; test_case
            "existing admin token is reused"
            `Quick
            test_existing_admin_token_is_reused
        ; test_case
            "invalid pending token fails closed"
            `Quick
            test_invalid_pending_token_fails_closed
        ; test_case
            "rotation write failure reuses pending token"
            `Quick
            test_rotation_write_failure_reuses_pending_token
        ] )
    ; ( "loopback admin issuance"
      , [ test_case
            "fresh issuance grants admin"
            `Quick
            test_fresh_issuance_grants_admin
        ] )
    ]
;;
