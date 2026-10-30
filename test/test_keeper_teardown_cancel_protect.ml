(** Turn teardown runs even when the caller's context is already cancelled.

    [Keeper_agent_run_turn_helpers.run_teardown_protected] is what removes a
    turn's sandbox container. It reaches `docker rm -f` through [Process_eio],
    and an Eio call made under a cancelled context raises [Cancelled] before it
    spawns anything, so the container survives for the life of the server. That
    [Cancelled] was also swallowed by a silent arm, which is why seven
    containers leaking over a 37-minute window produced no log line and no
    counter increment (#30590).

    [Eio.Fiber.check] stands in for `docker rm -f` here: it is the cheapest
    operation that raises exactly when an Eio call would refuse to start.

    The second case is the mutation. Without it the first would pass on the
    unfixed code too, because the body's first statement runs either way — only
    the work after the Eio call tells the two apart. *)

open Alcotest
module Turn_helpers = Masc.Keeper_agent_run_turn_helpers

exception Test_cancellation

type trace =
  { mutable entered : bool
  ; mutable finished : bool
  }

(* The teardown body: reach an Eio operation, then record that we got past it. *)
let body trace () =
  trace.entered <- true;
  Eio.Fiber.check ();
  trace.finished <- true
;;

(* Run [f] in a context that is cancelled before [f] starts. The [sub] re-raises
   the cancellation on the way out; that is the caller's concern, not the
   teardown's. *)
let under_cancelled_context f =
  let trace = { entered = false; finished = false } in
  (try
     Eio.Cancel.sub (fun ctx ->
       Eio.Cancel.cancel ctx Test_cancellation;
       f trace)
   with
   | Eio.Cancel.Cancelled _ -> ());
  trace
;;

let test_protected_teardown_completes () =
  Eio_main.run
  @@ fun _env ->
  let trace =
    under_cancelled_context (fun trace ->
      Turn_helpers.run_teardown_protected
        ~keeper_name:"test-keeper"
        ~site:"unit"
        (body trace))
  in
  check bool "teardown body started" true trace.entered;
  check bool "teardown finished its Eio work under cancellation" true trace.finished
;;

let test_unprotected_teardown_is_cut () =
  Eio_main.run
  @@ fun _env ->
  let trace =
    under_cancelled_context (fun trace ->
      try body trace () with
      | Eio.Cancel.Cancelled _ -> ())
  in
  check bool "mutation: the body still starts" true trace.entered;
  check
    bool
    "mutation: without the protection the Eio work never happens"
    false
    trace.finished
;;

(* Teardown is best effort: it must not let a failure reach the turn, or the
   turn's own outcome would be replaced by its cleanup's. *)
let test_raising_teardown_does_not_escape () =
  Eio_main.run
  @@ fun _env ->
  let raised = ref false in
  (try
     Turn_helpers.run_teardown_protected ~keeper_name:"test-keeper" ~site:"unit" (fun () ->
       failwith "teardown blew up")
   with
   | _ -> raised := true);
  check bool "a raising teardown is reported, not propagated" false !raised
;;

let () =
  run
    "keeper teardown cancel protect"
    [ ( "run_teardown_protected"
      , [ test_case "completes under cancellation" `Quick test_protected_teardown_completes
        ; test_case "mutation: unprotected body is cut" `Quick test_unprotected_teardown_is_cut
        ; test_case "raising teardown does not escape" `Quick test_raising_teardown_does_not_escape
        ] )
    ]
;;
