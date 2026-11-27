(* [bin/main_eio.ml]'s SIGTERM/SIGINT handler sets the global shutdown flag
   through [Shutdown.mark_shutting_down]. The keeper supervisor reads it with
   [is_shutting_down_global] to record a fiber cancelled by shutdown as
   [fiber_drop_cause.Graceful_shutdown] (PR #19346). These tests pin the
   marker's behaviour so the signal-handler wiring cannot silently regress. *)

module S = Masc.Shutdown

let mark_sets_global_flag () =
  Alcotest.(check bool)
    "global flag is false before mark"
    false
    (S.is_shutting_down_global ());
  S.mark_shutting_down ();
  Alcotest.(check bool)
    "global flag is true after mark"
    true
    (S.is_shutting_down_global ())

let mark_is_idempotent () =
  S.mark_shutting_down ();
  Alcotest.(check bool)
    "flag remains true after first call"
    true
    (S.is_shutting_down_global ());
  S.mark_shutting_down ();
  S.mark_shutting_down ();
  Alcotest.(check bool)
    "flag remains true after repeated calls"
    true
    (S.is_shutting_down_global ())

(* The flag is documented as sticky and process-global; once a previous test
   sets it via [mark_shutting_down] it cannot be observed as [false] again.
   We therefore run [mark_sets_global_flag] first (it asserts the [false]
   precondition) and then idempotency. *)
let () =
  Alcotest.run "shutdown_flag"
    [ "mark_shutting_down"
    , [ Alcotest.test_case "transitions false -> true" `Quick mark_sets_global_flag
      ; Alcotest.test_case "is idempotent" `Quick mark_is_idempotent
      ]
    ]
