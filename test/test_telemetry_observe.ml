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

    The Cancelled re-raise check is the load-bearing one — Step 5 of
    the plan removes the [Fun.protect] catch-all at
    keeper_agent_run.ml:157-164 and depends on this wrapper not
    swallowing cancel. *)

open Masc_mcp

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

let () =
  Alcotest.run "telemetry_observe"
    [
      ( "observe_or_fail",
        [
          Alcotest.test_case "returns Ok on success" `Quick
            test_observe_or_fail_returns_ok;
          Alcotest.test_case "returns Error on exception" `Quick
            test_observe_or_fail_returns_error;
          Alcotest.test_case "re-raises Eio.Cancel.Cancelled" `Quick
            test_observe_or_fail_reraises_cancelled;
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
    ]
