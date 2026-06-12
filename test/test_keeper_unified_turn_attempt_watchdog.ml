open Alcotest

module W = Masc.Keeper_unified_turn_attempt_watchdog
module Metrics = Masc.Otel_metric_store

let watchdog_metric = Keeper_metrics.(to_string AttemptWatchdogFired)

let watchdog_labels keeper = [ "keeper", keeper ]

let test_safety_deadline_records_terminal_reason_and_metric () =
  let keeper = "test-attempt-watchdog-state-loss" in
  let cancel_reasons = ref [] in
  let labels = watchdog_labels keeper in
  let before = Metrics.metric_value_or_zero watchdog_metric ~labels () in
  let raised =
    try
      ignore
        (Eio_main.run (fun env ->
           let clock = Eio.Stdenv.clock env in
           W.dispatch
             ~clock
             ~keeper_name:keeper
             ~attempt_watchdog_s:(Some 0.01)
             ~on_cancelled:(fun reason ->
               cancel_reasons := reason :: !cancel_reasons)
             ~run:(fun () ->
               Eio.Time.sleep clock 60.0;
               Ok ()))
         : (unit, Agent_sdk.Error.sdk_error) result);
      false
    with
    | Eio.Cancel.Cancelled (Failure msg) when String.equal msg "attempt_watchdog_safety_deadline" -> true
    | Eio.Cancel.Cancelled exn ->
      Alcotest.failf "unexpected cancellation: %s" (Printexc.to_string exn)
  in
  check bool "watchdog raises cancelled deadline" true raised;
  check (list string)
    "deadline reason recorded once"
    [ "attempt_watchdog_safety_deadline" ]
    (List.rev !cancel_reasons);
  check (float 0.0001)
    "attempt watchdog metric increments"
    (before +. 1.0)
    (Metrics.metric_value_or_zero watchdog_metric ~labels ())
;;

let test_external_cancel_records_external_reason_without_metric () =
  let keeper = "test-attempt-watchdog-external-cancel" in
  let cancel_reasons = ref [] in
  let labels = watchdog_labels keeper in
  let before = Metrics.metric_value_or_zero watchdog_metric ~labels () in
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
    (List.rev !cancel_reasons);
  check (float 0.0001)
    "external cancel does not increment watchdog metric"
    before
    (Metrics.metric_value_or_zero watchdog_metric ~labels ())
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
            "safety deadline records terminal reason and metric"
            `Quick
            test_safety_deadline_records_terminal_reason_and_metric
        ; test_case
            "external cancel records external reason without metric"
            `Quick
            test_external_cancel_records_external_reason_without_metric
        ; test_case
            "normal completion does not record cancel"
            `Quick
            test_normal_completion_does_not_record_cancel
        ] )
    ]
;;
