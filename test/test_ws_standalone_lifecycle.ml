open Alcotest
module WS = Server_ws_standalone.For_testing

let test_heartbeat_constants_sensible () =
  check (float 0.001) "heartbeat interval positive" 30.0 WS.heartbeat_interval_s;
  check int "default pong timeout intervals" 3 WS.pong_timeout_intervals
;;

let with_env_var name value f =
  let prev = try Some (Sys.getenv name) with Not_found -> None in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name "")
    f
;;

let test_missed_pong_threshold_configuration () =
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "" (fun () ->
    check int "default threshold" 3 (WS.missed_pong_threshold ()));
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "5" (fun () ->
    check int "env=5 → threshold 5" 5 (WS.missed_pong_threshold ()));
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "0" (fun () ->
    check int "env=0 disables threshold" 0 (WS.missed_pong_threshold ()));
  with_env_var "MASC_WS_MISSED_PONG_THRESHOLD" "-2" (fun () ->
    check int "negative values clamp to 0" 0 (WS.missed_pong_threshold ()))
;;

let test_accept_backoff_progression () =
  check (float 0.001) "initial backoff" 0.075 (WS.next_accept_backoff 0.05);
  check (float 0.001) "second backoff" 0.1125 (WS.next_accept_backoff 0.075);
  check (float 0.001) "exponential growth" 0.16875 (WS.next_accept_backoff 0.1125);
  check
    (float 0.001)
    "backs off until cap"
    WS.accept_backoff_cap_s
    (WS.next_accept_backoff WS.accept_backoff_cap_s);
  check
    (float 0.001)
    "stays at cap"
    WS.accept_backoff_cap_s
    (WS.next_accept_backoff WS.accept_backoff_cap_s)
;;

let () =
  run
    "ws_standalone_lifecycle"
    [ ( "heartbeat and accept backoff"
      , [ test_case
            "heartbeat constants are sensible"
            `Quick
            test_heartbeat_constants_sensible
        ; test_case
            "missed-pong threshold is configurable"
            `Quick
            test_missed_pong_threshold_configuration
        ; test_case
            "accept backoff progression caps"
            `Quick
            test_accept_backoff_progression
        ] )
    ]
;;
