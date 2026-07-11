open Alcotest

let request_with_headers headers =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    "/api/v1/dashboard/dev-token"
;;

let request ?host () =
  let headers =
    match host with
    | None -> []
    | Some value -> [ "host", value ]
  in
  request_with_headers headers
;;

let check_admitted raw expected_host expected_port =
  match Server_auth.admit_loopback_request_host (request ~host:raw ()) with
  | Ok admitted ->
    check string "host" expected_host admitted.host;
    check (option int) "port" expected_port admitted.port
  | Error _ -> failf "expected Host %S to be admitted" raw
;;

let test_exact_loopback_authorities () =
  check_admitted "localhost:8935" "localhost" (Some 8935);
  check_admitted " LOCALHOST:8935 " "localhost" (Some 8935);
  check_admitted "127.0.0.1" "127.0.0.1" None;
  check_admitted "[::1]:8935" "::1" (Some 8935);
  check_admitted "[0:0:0:0:0:0:0:1]" "0:0:0:0:0:0:0:1" None
;;

let test_malformed_suffixes_are_fully_rejected () =
  List.iter
    (fun raw ->
      match Server_auth.admit_loopback_request_host (request ~host:raw ()) with
      | Error Server_auth.Malformed_request_host -> ()
      | _ -> failf "Host %S must be rejected as malformed" raw)
    [ "localhost:8935<suffix>"
    ; "localhost:8935/ignored"
    ; "localhost:8935:80"
    ; "localhost:"
    ; "localhost:65536"
    ; "localhost#fragment"
    ; "user@localhost:8935"
    ; "[::1]garbage"
    ; "[::1]:8935garbage"
    ]
;;

let test_host_rejections_are_typed () =
  (match Server_auth.admit_loopback_request_host (request ()) with
   | Error Server_auth.Missing_request_host -> ()
   | _ -> fail "missing Host must have a typed rejection");
  let repeated_host_request =
    request_with_headers [ "Host", "localhost"; "hOsT", "localhost" ]
  in
  (match
     Server_auth.admit_loopback_request_host repeated_host_request
   with
   | Error Server_auth.Multiple_request_hosts -> ()
   | _ -> fail "multiple Host field lines must have a typed rejection");
  (match Server_auth.host_port_of_request repeated_host_request with
   | None -> ()
   | Some _ -> fail "generic Host projection must reject multiple field lines");
  (match
     Server_auth.admit_loopback_request_host
       (request ~host:"localhost/path" ())
   with
   | Error Server_auth.Malformed_request_host -> ()
   | _ -> fail "Host containing a path must be malformed");
  (match
     Server_auth.admit_loopback_request_host
       (request ~host:"attacker.example:8935" ())
   with
   | Error (Server_auth.Non_loopback_request_host "attacker.example") -> ()
   | _ -> fail "non-loopback Host must retain its typed rejection")
;;

let test_request_error_statuses () =
  let status_of rejection =
    Server_routes_http_dashboard_dev_token.request_error_status
      (Server_routes_http_dashboard_dev_token.Request_host_rejected rejection)
    |> Httpun.Status.to_code
  in
  check int "missing Host" 400 (status_of Server_auth.Missing_request_host);
  check int "multiple Host fields" 400 (status_of Server_auth.Multiple_request_hosts);
  check int "malformed Host" 400 (status_of Server_auth.Malformed_request_host);
  check
    string
    "multiple Host error code"
    "dashboard_dev_token_host_multiple"
    (Server_routes_http_dashboard_dev_token.request_error_code
       (Server_routes_http_dashboard_dev_token.Request_host_rejected
          Server_auth.Multiple_request_hosts));
  check
    int
    "valid non-loopback Host"
    403
    (status_of (Server_auth.Non_loopback_request_host "attacker.example"))
;;

let test_rejection_precedes_token_io () =
  let base_path = Filename.temp_file "masc-dev-token-host-" ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists base_path then Unix.rmdir base_path)
    (fun () ->
       List.iter
         (fun (label, request) ->
           match
             Server_routes_http_dashboard_dev_token
             .ensure_dashboard_dev_token_for_request
               ~request
               ~base_path
           with
           | Error
               (Server_routes_http_dashboard_dev_token.Request_host_rejected _) ->
             check bool "base path remains absent" false (Sys.file_exists base_path)
           | _ -> failf "%s must fail before token I/O" label)
         [ "missing Host", request ()
         ; ( "multiple Host fields"
           , request_with_headers
               [ "host", "localhost:8935"; "host", "localhost:8935" ] )
         ; "non-loopback Host", request ~host:"attacker.example" ()
         ; "malformed Host", request ~host:"localhost:8935<suffix>" ()
         ])
;;

let () =
  run
    "dashboard-dev-token-host-gate"
    [ ( "host admission"
      , [ test_case "exact loopback authorities" `Quick test_exact_loopback_authorities
        ; test_case
            "malformed suffixes are fully rejected"
            `Quick
            test_malformed_suffixes_are_fully_rejected
        ; test_case "typed rejections" `Quick test_host_rejections_are_typed
        ; test_case "HTTP status mapping" `Quick test_request_error_statuses
        ; test_case "rejection precedes token I/O" `Quick test_rejection_precedes_token_io
        ] )
    ]
;;
