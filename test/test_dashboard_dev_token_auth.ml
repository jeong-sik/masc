let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest

module Dev_token = Server_routes_http_dashboard_dev_token

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_workspace f =
  let path = Filename.temp_file "masc-dashboard-token-" ".workspace" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let request ?host () =
  let headers =
    match host with
    | None -> []
    | Some value -> [ "host", value ]
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    "/api/v1/dashboard/dev-token"

let run_eio f = Eio_main.run (fun _env -> f ())

let check_host_ok raw expected_host expected_port =
  match Server_auth.admit_loopback_request_host (request ~host:raw ()) with
  | Ok admitted ->
      check string "host" expected_host admitted.host;
      check (option int) "port" expected_port admitted.port
  | Error _ -> failf "expected Host %S to be admitted" raw

let test_exact_loopback_host_admission () =
  check_host_ok "localhost:8935" "localhost" (Some 8935);
  check_host_ok "127.0.0.1" "127.0.0.1" None;
  check_host_ok "[::1]:8935" "::1" (Some 8935)

let test_host_rejections_are_typed () =
  (match Server_auth.admit_loopback_request_host (request ()) with
   | Error Server_auth.Missing_request_host -> ()
   | _ -> fail "missing Host must be rejected as Missing_request_host");
  (match
     Server_auth.admit_loopback_request_host
       (request ~host:"localhost/path" ())
   with
   | Error Server_auth.Malformed_request_host -> ()
   | _ -> fail "Host with a path must be rejected as malformed");
  (match
     Server_auth.admit_loopback_request_host
       (request ~host:"attacker.example:8935" ())
   with
   | Error (Server_auth.Non_loopback_request_host "attacker.example") -> ()
   | _ -> fail "non-loopback Host must remain a typed rejection")

let test_host_rejection_precedes_token_io () =
  with_temp_workspace @@ fun base_path ->
  run_eio @@ fun () ->
  let result =
    Dev_token.ensure_dashboard_dev_token_for_request
      ~mutex:(Eio.Mutex.create ())
      ~request:(request ~host:"attacker.example" ())
      ~base_path
  in
  (match result with
   | Error
       (Dev_token.Request_host_rejected
          (Server_auth.Non_loopback_request_host _)) ->
       ()
   | _ -> fail "non-loopback request must fail before token I/O");
  check bool ".masc was not created" false
    (Sys.file_exists (Common.masc_dir_from_base_path ~base_path))

let test_admin_token_rotates_once_to_worker () =
  with_temp_workspace @@ fun base_path ->
  let old_raw =
    match
      Auth.create_token
        base_path
        ~agent_name:"dashboard"
        ~role:Masc_domain.Admin
    with
    | Ok (raw, _) -> raw
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  let token_path = Dev_token.dashboard_dev_token_path base_path in
  Auth.save_private_text_file token_path old_raw;
  run_eio @@ fun () ->
  let mutex = Eio.Mutex.create () in
  let new_raw =
    match Dev_token.ensure_dashboard_dev_token ~mutex base_path with
    | Ok raw -> raw
    | Error err -> fail (Dev_token.error_to_string err)
  in
  check bool "raw token changed" true (not (String.equal old_raw new_raw));
  (match Auth.find_credential_by_token base_path ~token:old_raw with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
   | _ -> fail "old Admin bearer must be invalid after rotation");
  (match Auth.find_credential_by_token base_path ~token:new_raw with
   | Ok credential ->
       check string "owner" "dashboard" credential.agent_name;
       (match credential.role with
        | Masc_domain.Worker -> ()
        | Masc_domain.Admin -> fail "new dashboard token must not be Admin")
   | Error err -> fail (Masc_domain.masc_error_to_string err));
  let second =
    match Dev_token.ensure_dashboard_dev_token ~mutex base_path with
    | Ok raw -> raw
    | Error err -> fail (Dev_token.error_to_string err)
  in
  check string "Worker token is reused" new_raw second;
  check bool "journal removed" false
    (Sys.file_exists (Dev_token.dashboard_dev_token_rotation_path base_path));
  check int "token mode" 0o600 ((Unix.stat token_path).Unix.st_perm land 0o777)

let test_pending_rotation_resumes_exact_token () =
  with_temp_workspace @@ fun base_path ->
  let pending_raw = Auth.generate_token () in
  let journal_path = Dev_token.dashboard_dev_token_rotation_path base_path in
  Fs_compat.mkdir_p (Filename.dirname journal_path);
  Auth.save_private_text_file journal_path pending_raw;
  run_eio @@ fun () ->
  let result =
    Dev_token.ensure_dashboard_dev_token
      ~mutex:(Eio.Mutex.create ())
      base_path
  in
  let raw =
    match result with
    | Ok value -> value
    | Error err -> fail (Dev_token.error_to_string err)
  in
  check string "journal token is resumed" pending_raw raw;
  check bool "journal finalized" false (Sys.file_exists journal_path)

let test_invalid_rotation_journal_fails_closed () =
  with_temp_workspace @@ fun base_path ->
  let journal_path = Dev_token.dashboard_dev_token_rotation_path base_path in
  Fs_compat.mkdir_p (Filename.dirname journal_path);
  Auth.save_private_text_file journal_path "not-a-generated-token";
  run_eio @@ fun () ->
  let result =
    Dev_token.ensure_dashboard_dev_token
      ~mutex:(Eio.Mutex.create ())
      base_path
  in
  (match result with
   | Error (Dev_token.Rotation_journal_invalid _) -> ()
   | _ -> fail "invalid journal must not trigger replacement minting");
  check int "no credential minted" 0 (List.length (Auth.list_credentials base_path))

let test_token_write_failure_resumes_without_remint () =
  with_temp_workspace @@ fun base_path ->
  let old_raw =
    match
      Auth.create_token
        base_path
        ~agent_name:"dashboard"
        ~role:Masc_domain.Admin
    with
    | Ok (raw, _) -> raw
    | Error err -> fail (Masc_domain.masc_error_to_string err)
  in
  let pending_raw = Auth.generate_token () in
  let journal_path = Dev_token.dashboard_dev_token_rotation_path base_path in
  let token_path = Dev_token.dashboard_dev_token_path base_path in
  Fs_compat.mkdir_p (Filename.dirname journal_path);
  Auth.save_private_text_file token_path old_raw;
  Auth.save_private_text_file journal_path pending_raw;
  Sys.remove token_path;
  Unix.mkdir token_path 0o700;
  run_eio @@ fun () ->
  let mutex = Eio.Mutex.create () in
  (match Dev_token.ensure_dashboard_dev_token ~mutex base_path with
   | Error (Dev_token.Token_file_write_failed _) -> ()
   | _ -> fail "raw-token write failure must leave rotation pending");
  (match Auth.find_credential_by_token base_path ~token:old_raw with
   | Error (Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken _)) -> ()
   | _ -> fail "failed raw-token persistence must not reactivate Admin bearer");
  check bool "journal remains" true (Sys.file_exists journal_path);
  check int "journal mode" 0o600
    ((Unix.stat journal_path).Unix.st_perm land 0o777);
  Unix.rmdir token_path;
  let resumed =
    match Dev_token.ensure_dashboard_dev_token ~mutex base_path with
    | Ok raw -> raw
    | Error err -> fail (Dev_token.error_to_string err)
  in
  check string "retry uses the journal token" pending_raw resumed;
  check bool "journal finalized after repair" false (Sys.file_exists journal_path)

let test_token_read_failure_does_not_mint () =
  with_temp_workspace @@ fun base_path ->
  let token_path = Dev_token.dashboard_dev_token_path base_path in
  Fs_compat.mkdir_p token_path;
  run_eio @@ fun () ->
  let result =
    Dev_token.ensure_dashboard_dev_token
      ~mutex:(Eio.Mutex.create ())
      base_path
  in
  (match result with
   | Error (Dev_token.Token_file_read_failed _) -> ()
   | _ -> fail "token read failure must be explicit and fail closed");
  check int "no credential minted" 0 (List.length (Auth.list_credentials base_path))

let () =
  Alcotest.run
    "dashboard-dev-token-auth"
    [ ( "host-admission",
        [ test_case "exact loopback authorities" `Quick
            test_exact_loopback_host_admission
        ; test_case "typed rejection" `Quick test_host_rejections_are_typed
        ; test_case "admission precedes I/O" `Quick
            test_host_rejection_precedes_token_io
        ] )
    ; ( "rotation",
        [ test_case "Admin rotates once to Worker" `Quick
            test_admin_token_rotates_once_to_worker
        ; test_case "pending journal resumes exact token" `Quick
            test_pending_rotation_resumes_exact_token
        ; test_case "invalid journal fails closed" `Quick
            test_invalid_rotation_journal_fails_closed
        ; test_case "write failure resumes without remint" `Quick
            test_token_write_failure_resumes_without_remint
        ; test_case "read failure does not mint" `Quick
            test_token_read_failure_does_not_mint
        ] )
    ]
