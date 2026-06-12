open Alcotest

module W = Masc.Keeper_unified_turn_attempt_watchdog

let test_no_masc_wall_clock_timeout_for_tool_like_work () =
  let keeper = "test-attempt-watchdog-no-tool-timeout" in
  let cancel_reasons = ref [] in
  let outcome =
    try
      Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        W.dispatch
          ~clock
          ~keeper_name:keeper
          ~attempt_watchdog_s:(Some 0.01)
          ~on_cancelled:(fun reason ->
            cancel_reasons := reason :: !cancel_reasons)
          ~run:(fun () ->
            Eio.Time.sleep clock 0.05;
            Ok "tool-finished"))
    with
    | Eio.Cancel.Cancelled exn ->
      Alcotest.failf "unexpected cancellation: %s" (Printexc.to_string exn)
  in
  (match outcome with
   | Ok value -> check string "tool-like work is allowed to finish" "tool-finished" value
   | Error err ->
     Alcotest.failf "unexpected error: %s" (Agent_sdk.Error.to_string err));
  check (list string) "no cancel reason" [] !cancel_reasons
;;

let test_external_cancel_records_external_reason () =
  let keeper = "test-attempt-watchdog-external-cancel" in
  let cancel_reasons = ref [] in
  let raised =
    try
      ignore
        (Eio_main.run (fun env ->
           W.dispatch
             ~clock:(Eio.Stdenv.clock env)
             ~keeper_name:keeper
             ~attempt_watchdog_s:(Some 60.0)
             ~on_cancelled:(fun reason ->
               cancel_reasons := reason :: !cancel_reasons)
             ~run:(fun () ->
               raise (Eio.Cancel.Cancelled (Failure "external-cancel-test"))))
         : (unit, Agent_sdk.Error.sdk_error) result);
      false
    with
    | Eio.Cancel.Cancelled (Failure msg) when String.equal msg "external-cancel-test" -> true
    | Eio.Cancel.Cancelled exn ->
      Alcotest.failf "unexpected cancellation: %s" (Printexc.to_string exn)
  in
  check bool "external cancel is re-raised" true raised;
  check (list string)
    "external cancel reason recorded once"
    [ "external_cancel" ]
    (List.rev !cancel_reasons)
;;

let test_normal_completion_does_not_record_cancel () =
  let cancel_reasons = ref [] in
  let outcome =
    Eio_main.run (fun env ->
      W.dispatch
        ~clock:(Eio.Stdenv.clock env)
        ~keeper_name:"test-attempt-watchdog-normal"
        ~attempt_watchdog_s:(Some 60.0)
        ~on_cancelled:(fun reason -> cancel_reasons := reason :: !cancel_reasons)
        ~run:(fun () -> Ok "done"))
  in
  (match outcome with
   | Ok value -> check string "normal result passes through" "done" value
   | Error err ->
     Alcotest.failf "unexpected error: %s" (Agent_sdk.Error.to_string err));
  check (list string) "no cancel reason" [] !cancel_reasons
;;

let () =
  run "keeper_unified_turn_attempt_watchdog"
    [ ( "state_loss_regression"
      , [ test_case
            "does not create MASC wall-clock timeout"
            `Quick
            test_no_masc_wall_clock_timeout_for_tool_like_work
        ; test_case
            "external cancel records external reason"
            `Quick
            test_external_cancel_records_external_reason
        ; test_case
            "normal completion does not record cancel"
            `Quick
            test_normal_completion_does_not_record_cancel
        ] )
    ]
;;
