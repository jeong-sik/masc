(** test_telemetry_observe — Unit tests for [Telemetry_observe].

    Step 15 (partial) of the bloodflow restoration plan. Covers the
    silent-failure wrapper introduced in Step 0b
    (lib/telemetry_observe.{ml,mli}). Verifies that:

    - [observe_or_fail] returns [Ok] on success.
    - [observe_or_fail] returns [Error msg] on a generic exception.
    - [observe_or_fail] re-raises [Eio.Cancel.Cancelled] without
      silently absorbing it (cooperative-cancel preservation).
    - [observe_or_default] returns the success value on [Ok].
    - [observe_or_default] returns the [default] on exception.
    - [observe_silent] absorbs ordinary exceptions without logging through
      the same warning path and preserves [Eio.Cancel.Cancelled].

    The Cancelled re-raise check is the load-bearing one — Step 5 of
    the plan removes the [Fun.protect] catch-all at
    keeper_agent_run.ml:157-164 and depends on this wrapper not
    swallowing cancel. *)

open Masc_mcp

let failure_metric_value kind =
  Prometheus.metric_value_or_zero Prometheus.metric_telemetry_observe_failures
    ~labels:[("kind", kind)] ()

let test_observe_or_fail_returns_ok () =
  let result =
    Telemetry_observe.observe_or_fail ~kind:"test_ok" (fun () -> 42)
  in
  Alcotest.(check (result int string)) "Ok 42" (Ok 42) result

let test_observe_or_fail_returns_error () =
  let result =
    Telemetry_observe.observe_or_fail ~kind:"test_failure" (fun () ->
        raise (Failure "synthetic-failure"))
  in
  match result with
  | Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Error msg ->
      Alcotest.(check bool)
        "Error message contains [synthetic-failure]"
        true
        (try
           ignore (Str.search_forward (Str.regexp_string "synthetic-failure") msg 0);
           true
         with Not_found -> false)

let test_observe_or_fail_counts_exception () =
  let kind = "test_observe_or_fail_counts_exception" in
  let before = failure_metric_value kind in
  let result =
    Telemetry_observe.observe_or_fail ~kind (fun () ->
        raise (Failure "synthetic-metric-failure"))
  in
  (match result with
  | Ok _ -> Alcotest.fail "expected Error, got Ok"
  | Error _ -> ());
  let after = failure_metric_value kind in
  Alcotest.(check (float 0.0001))
    "failure counter increments once" (before +. 1.0) after

let test_observe_or_fail_success_does_not_count () =
  let kind = "test_observe_or_fail_success_does_not_count" in
  let before = failure_metric_value kind in
  let result = Telemetry_observe.observe_or_fail ~kind (fun () -> 11) in
  Alcotest.(check (result int string)) "Ok 11" (Ok 11) result;
  let after = failure_metric_value kind in
  Alcotest.(check (float 0.0001))
    "success leaves failure counter unchanged" before after

let test_observe_or_fail_reraises_cancelled () =
  let raised = ref false in
  (try
     let _ =
       Telemetry_observe.observe_or_fail ~kind:"test_cancel" (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "synthetic-cancel")))
     in
     ()
   with
  | Eio.Cancel.Cancelled _ -> raised := true);
  Alcotest.(check bool)
    "Eio.Cancel.Cancelled was re-raised, not swallowed"
    true !raised

let test_observe_or_fail_cancelled_does_not_count () =
  let kind = "test_observe_or_fail_cancelled_does_not_count" in
  let before = failure_metric_value kind in
  (try
     let _ =
       Telemetry_observe.observe_or_fail ~kind (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "synthetic-cancel")))
     in
     ()
   with
  | Eio.Cancel.Cancelled _ -> ());
  let after = failure_metric_value kind in
  Alcotest.(check (float 0.0001))
    "Cancelled leaves failure counter unchanged" before after

let test_observe_or_default_returns_value () =
  let v =
    Telemetry_observe.observe_or_default ~kind:"test_default_ok"
      ~default:0 (fun () -> 7)
  in
  Alcotest.(check int) "success returns 7" 7 v

let test_observe_or_default_returns_default_on_exception () =
  let v =
    Telemetry_observe.observe_or_default ~kind:"test_default_err"
      ~default:99 (fun () -> raise (Failure "boom"))
  in
  Alcotest.(check int) "exception returns default 99" 99 v

let test_observe_or_default_reraises_cancelled () =
  let raised = ref false in
  (try
     let _ =
       Telemetry_observe.observe_or_default ~kind:"test_default_cancel"
         ~default:0 (fun () ->
           raise (Eio.Cancel.Cancelled (Failure "synthetic-cancel")))
     in
     ()
   with
  | Eio.Cancel.Cancelled _ -> raised := true);
  Alcotest.(check bool)
    "observe_or_default also re-raises Cancelled"
    true !raised

let test_observe_silent_absorbs_exception () =
  Telemetry_observe.observe_silent ~kind:"test_silent_err" (fun () ->
      raise (Failure "silent boom"));
  Alcotest.(check bool) "ordinary exception absorbed" true true

let test_observe_silent_reraises_cancelled () =
  let raised = ref false in
  (try
     Telemetry_observe.observe_silent ~kind:"test_silent_cancel" (fun () ->
         raise (Eio.Cancel.Cancelled (Failure "synthetic-cancel")))
   with
  | Eio.Cancel.Cancelled _ -> raised := true);
  Alcotest.(check bool)
    "observe_silent also re-raises Cancelled"
    true !raised

let () =
  Alcotest.run "telemetry_observe"
    [
      ( "observe_or_fail",
        [
          Alcotest.test_case "returns Ok on success" `Quick
            test_observe_or_fail_returns_ok;
          Alcotest.test_case "returns Error on exception" `Quick
            test_observe_or_fail_returns_error;
          Alcotest.test_case "counts exception" `Quick
            test_observe_or_fail_counts_exception;
          Alcotest.test_case "success does not count" `Quick
            test_observe_or_fail_success_does_not_count;
          Alcotest.test_case "re-raises Eio.Cancel.Cancelled" `Quick
            test_observe_or_fail_reraises_cancelled;
          Alcotest.test_case "Cancelled does not count" `Quick
            test_observe_or_fail_cancelled_does_not_count;
        ] );
      ( "observe_or_default",
        [
          Alcotest.test_case "returns value on success" `Quick
            test_observe_or_default_returns_value;
          Alcotest.test_case "returns default on exception" `Quick
            test_observe_or_default_returns_default_on_exception;
          Alcotest.test_case "re-raises Eio.Cancel.Cancelled" `Quick
            test_observe_or_default_reraises_cancelled;
        ] );
      ( "observe_silent",
        [
          Alcotest.test_case "absorbs ordinary exception" `Quick
            test_observe_silent_absorbs_exception;
          Alcotest.test_case "re-raises Eio.Cancel.Cancelled" `Quick
            test_observe_silent_reraises_cancelled;
        ] );
    ]
