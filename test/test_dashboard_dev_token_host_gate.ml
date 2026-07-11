open Alcotest

let request ?host () =
  let headers =
    match host with
    | None -> Httpun.Headers.empty
    | Some value -> Httpun.Headers.of_list [ "host", value ]
  in
  Httpun.Request.create ~headers `GET "/api/v1/dashboard/dev-token"
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

let test_rejection_precedes_token_io () =
  let base_path = Filename.temp_file "masc-dev-token-host-" ".workspace" in
  Sys.remove base_path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists base_path then Unix.rmdir base_path)
    (fun () ->
       List.iter
         (fun raw ->
           match
             Server_routes_http_dashboard_dev_token
             .ensure_dashboard_dev_token_for_request
               ~request:(request ~host:raw ())
               ~base_path
           with
           | Error
               (Server_routes_http_dashboard_dev_token.Request_host_rejected _) ->
             check bool "base path remains absent" false (Sys.file_exists base_path)
           | _ -> failf "Host %S must fail before token I/O" raw)
         [ "attacker.example"; "localhost:8935<suffix>" ])
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
        ; test_case "rejection precedes token I/O" `Quick test_rejection_precedes_token_io
        ] )
    ]
;;
