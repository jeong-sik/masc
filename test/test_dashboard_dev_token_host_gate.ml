open Alcotest

module Dev_token = Server_routes_http_dashboard_dev_token

let authority_exn raw =
  let request =
    Httpun.Request.create
      ~headers:(Httpun.Headers.of_list [ "host", raw ])
      `GET
      "/api/v1/dashboard/dev-token"
  in
  match Server_request_authority.classify_http1_request request with
  | Server_request_authority.Single authority -> authority
  | ( Server_request_authority.Missing
    | Server_request_authority.Multiple
    | Server_request_authority.Malformed ) ->
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

let () =
  run
    "dashboard-dev-token-host-gate"
    [ ( "validated authority policy"
      , [ test_case "non-loopback error contract" `Quick test_non_loopback_error_contract
        ; test_case
            "non-loopback rejected before token I/O"
            `Quick
            test_non_loopback_rejection_precedes_token_io
        ] )
    ]
;;
