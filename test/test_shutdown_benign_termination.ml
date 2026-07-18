(** Unit tests for [Shutdown.is_benign_termination] — recognising a graceful
    shutdown that Eio combined with an in-flight finalizer exception, so the
    process entrypoint does not misclassify it as a crash and exit 1 (#25118).

    The realistic shape matters: ending shutdown cancels in-flight fibers, a
    cancellable [Fun.protect] finalizer raises [Cancelled] wrapped as
    [Fun.Finally_raised], and [Eio.Exn.combine] KEEPS that wrapper over a bare
    [Cancelled] (it discards bare [Cancelled] in favour of "something better").
    Tests therefore build members through [Eio.Exn.combine] rather than
    hand-rolling an [Eio.Exn.Multiple] that [combine] would never produce. *)

module Shutdown = Masc.Shutdown

(* Stand-in for the entrypoint's leaf classifier. *)
exception Graceful_shutdown

let benign = function
  | Graceful_shutdown -> true
  | Eio.Cancel.Cancelled _ -> true
  | _ -> false

let bt = Printexc.get_raw_backtrace ()
let with_bt e = e, bt

(* The finalizer exception actually observed at shutdown: a cancellable
   finalizer raised [Cancelled], wrapped by [Fun.protect] as [Finally_raised]. *)
let finalizer_exn = Stdlib.Fun.Finally_raised (Eio.Cancel.Cancelled Graceful_shutdown)

(* What Eio actually re-raises: combine drops the bare cancel and keeps the
   finalizer wrapper alongside the switch's [Graceful_shutdown]. *)
let combined_shutdown =
  fst (Eio.Exn.combine (with_bt Graceful_shutdown) (with_bt finalizer_exn))

let check name expected exn =
  Alcotest.(check bool) name expected (Shutdown.is_benign_termination ~benign exn)

let test_bare_benign () = check "bare Graceful_shutdown is benign" true Graceful_shutdown
let test_bare_non_benign () = check "unrelated exception is not benign" false (Failure "boom")

let test_finalizer_wrapper_is_benign () =
  check "Fun.Finally_raised (Cancelled _) unwraps to a benign leaf" true finalizer_exn

let test_real_combined_shutdown_is_benign () =
  (* The exact value the entrypoint receives — must NOT be a FATAL crash. *)
  check
    "Eio-combined [Graceful_shutdown + Finally_raised(Cancelled)] is benign"
    true
    combined_shutdown

let test_combined_with_real_error_is_not_benign () =
  let combined =
    fst (Eio.Exn.combine (with_bt Graceful_shutdown) (with_bt (Failure "disk full")))
  in
  check "a genuine error combined with shutdown is not benign" false combined

let test_empty_multiple_is_not_benign () =
  check "an empty Multiple asserts nothing and is not benign" false (Eio.Exn.Multiple [])

let () =
  Alcotest.run
    "shutdown_benign_termination"
    [ ( "is_benign_termination"
      , [ Alcotest.test_case "bare benign" `Quick test_bare_benign
        ; Alcotest.test_case "bare non-benign" `Quick test_bare_non_benign
        ; Alcotest.test_case "finalizer wrapper" `Quick test_finalizer_wrapper_is_benign
        ; Alcotest.test_case "real combined shutdown" `Quick
            test_real_combined_shutdown_is_benign
        ; Alcotest.test_case "combined with real error" `Quick
            test_combined_with_real_error_is_not_benign
        ; Alcotest.test_case "empty multiple" `Quick test_empty_multiple_is_not_benign
        ] )
    ]
