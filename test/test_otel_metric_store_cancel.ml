(** [Otel_metric_store_core] must not absorb [Eio.Cancel.Cancelled] (#37349).

    Metric calls reach the store from fibers a turn can cancel: the keeper
    lifecycle listener bumps [metric_keeper_lifecycle_malformed] on a payload it
    could not decode, and turn teardown bumps counters while unwinding. Until
    #37349 the store's [best_effort] wrapper caught every exception, so a
    [Cancelled] raised under it would have become a warning line and the caller
    would have carried on.

    Nothing inside the store suspends today — [metric_key] is string work and
    the lock is [Stdlib.Mutex] — so [Cancelled] cannot originate under
    [best_effort], and these cases do not reproduce a raise the store cannot
    make. What they pin is the boundary the store presents to a fiber that is
    already cancelled: the pending cancellation is still pending afterwards, and
    a sample taken under [Eio.Cancel.protect] is still recorded. They fail if a
    metric call ever starts eating a cancellation. *)

open Alcotest

let counter = "masc_test_otel_metric_store_cancel_total"
let near = float 1e-9
let value ?(labels = []) () = Otel_metric_store_core.metric_value_or_zero counter ~labels ()

(* [Cancel.sub] runs the body in a child context. Cancelling that context from
   inside it leaves the fiber running until its next cancellation point, which
   is how a keeper turn reaches the store after the turn was already cancelled. *)
let run_in_cancelled_sub ~reason body =
  let escaped = ref None in
  (try
     Eio.Cancel.sub (fun cc ->
       Eio.Cancel.cancel cc (Failure reason);
       body ();
       Eio.Fiber.check ())
   with
   | Eio.Cancel.Cancelled ex -> escaped := Some (Printexc.to_string ex));
  !escaped
;;

let cancelled_by reason = Some (Printexc.to_string (Failure reason))

let test_pending_cancellation_survives_a_metric_call () =
  Eio_main.run
  @@ fun _env ->
  let before = value () in
  let escaped =
    run_in_cancelled_sub ~reason:"turn cancelled" (fun () ->
      Otel_metric_store_core.inc_counter counter ())
  in
  check
    (option string)
    "the cancellation reached the caller"
    (cancelled_by "turn cancelled")
    escaped;
  check near "the sample was still recorded" (before +. 1.0) (value ())
;;

let test_metric_call_under_cancel_protect_records_and_cancellation_resumes () =
  Eio_main.run
  @@ fun _env ->
  let labels = [ "phase", "teardown" ] in
  let before = value ~labels () in
  let escaped =
    (* The teardown shape keeper_unified_turn and keeper_msg_async use: count
       under [Cancel.protect], then let the cancellation continue. *)
    run_in_cancelled_sub ~reason:"shutdown" (fun () ->
      Eio.Cancel.protect (fun () ->
        Otel_metric_store_core.inc_counter counter ~labels ()))
  in
  check
    (option string)
    "the protected metric call did not consume the cancellation"
    (cancelled_by "shutdown")
    escaped;
  check near "the protected sample was recorded" (before +. 1.0) (value ~labels ())
;;

let test_metric_call_outside_cancellation_is_unchanged () =
  Eio_main.run
  @@ fun _env ->
  let labels = [ "phase", "running" ] in
  let before = value ~labels () in
  Otel_metric_store_core.inc_counter counter ~labels ();
  check near "an uncancelled fiber still records" (before +. 1.0) (value ~labels ())
;;

let () =
  run
    "otel_metric_store_cancel"
    [ ( "cancelled scope"
      , [ test_case
            "a pending cancellation survives a metric call"
            `Quick
            test_pending_cancellation_survives_a_metric_call
        ; test_case
            "a metric call under Cancel.protect records and the cancellation resumes"
            `Quick
            test_metric_call_under_cancel_protect_records_and_cancellation_resumes
        ] )
    ; ( "uncancelled scope"
      , [ test_case
            "a metric call outside cancellation is unchanged"
            `Quick
            test_metric_call_outside_cancellation_is_unchanged
        ] )
    ]
;;
