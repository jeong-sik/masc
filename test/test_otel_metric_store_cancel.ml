(** [Otel_metric_store_core] must not absorb [Eio.Cancel.Cancelled] (#37349).

    Metric calls reach the store from fibers a turn can cancel: the keeper
    lifecycle listener bumps [metric_keeper_lifecycle_malformed] on a payload it
    could not decode, and turn teardown bumps counters while unwinding. Until
    #37349 the store's [best_effort] wrapper caught every exception, so a
    [Cancelled] raised under it would have become a warning line and the caller
    would have carried on.

    Two kinds of case here, and they prove different things.

    The source-structure cases are the ones that fail on main. They pin that
    [best_effort] routes through [Cancel_safe.observe] and that every public
    updater still goes through [best_effort]. A behavioural case cannot reach
    this: nothing under [best_effort] suspends ([metric_key] is string work, the
    lock is [Stdlib.Mutex]), so [Cancelled] has no way to originate there, and a
    swallowing [best_effort] passes every runtime case below.

    The Eio cases pin what the store shows a fiber that is already cancelled: a
    metric call adds no cancellation point of its own, and it still records
    while a cancellation is pending. That is what the teardown call sites
    depend on. They do not prove the re-raise. *)

open Alcotest

let store_source = "lib/otel_metric_store/otel_metric_store_core.ml"
let counter = "masc_test_otel_metric_store_cancel_total"
let near = float 1e-9

let value ?(labels = []) () =
  Otel_metric_store_core.metric_value_or_zero counter ~labels ()
;;

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

let test_best_effort_routes_through_cancel_safe () =
  check
    int
    "best_effort is a Cancel_safe.observe call site"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:store_source
       ~binding_name:"best_effort"
       ~callee:"Cancel_safe.observe")
;;

(* [best_effort] is not in the .mli, so this list is the store's whole exposure
   to a cancelled fiber. A new updater that writes its own [try ... with]
   instead of reusing the wrapper would leave that list without failing
   anything; this is what notices. *)
let test_every_updater_goes_through_best_effort () =
  List.iter
    (fun binding_name ->
       check
         int
         (Printf.sprintf "%s wraps its body in best_effort" binding_name)
         1
         (Ast_grep.count_calls_in_value_binding
            ~module_path:store_source
            ~binding_name
            ~callee:"best_effort"))
    [ "register_counter"
    ; "register_gauge"
    ; "register_histogram"
    ; "register_histogram_buckets"
    ; "inc_counter"
    ; "set_gauge"
    ; "inc_gauge"
    ; "observe_histogram"
    ]
;;

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
    (* The shape keeper_vision_tool and keeper_msg_async use: count under
       [Cancel.protect], then let the cancellation continue. *)
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
    [ ( "source structure"
      , [ test_case
            "best_effort routes through Cancel_safe.observe"
            `Quick
            test_best_effort_routes_through_cancel_safe
        ; test_case
            "every updater goes through best_effort"
            `Quick
            test_every_updater_goes_through_best_effort
        ] )
    ; ( "cancelled scope"
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
