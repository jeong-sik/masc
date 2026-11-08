(** Tests for [Cancel_safe.protect]/[observe] — the RFC-0106 SSOT that
    re-raises [Eio.Cancel.Cancelled] (so cooperative cancellation propagates)
    while routing any other exception to [on_exn]. The keeper turn/create hot
    paths delegate to this combinator; its correctness is what makes those
    catch-alls cancel-safe. *)

open Alcotest

let test_reraises_cancelled () =
  let on_exn_called = ref false in
  let reraised = ref false in
  (try
     ignore
       (Cancel_safe.protect
          ~on_exn:(fun _ ->
            on_exn_called := true;
            0)
          (fun () -> raise (Eio.Cancel.Cancelled (Failure "boom"))))
   with
   | Eio.Cancel.Cancelled _ -> reraised := true);
  check bool "Cancelled propagated to caller" true !reraised;
  check bool "on_exn NOT invoked for Cancelled" false !on_exn_called

let test_routes_other_exn () =
  let r =
    Cancel_safe.protect ~on_exn:(fun _ -> 42) (fun () -> raise (Failure "x"))
  in
  check int "on_exn result becomes the value" 42 r

let test_passes_through_success () =
  let r = Cancel_safe.protect ~on_exn:(fun _ -> 0) (fun () -> 7) in
  check int "success value returned unchanged" 7 r

let test_observe_routes_then_reraises () =
  let logged = ref false in
  Cancel_safe.observe
    ~on_exn:(fun _ -> logged := true)
    (fun () -> raise (Failure "y"));
  check bool "observe routes other exn to on_exn" true !logged;
  let reraised = ref false in
  (try
     Cancel_safe.observe
       ~on_exn:(fun _ -> ())
       (fun () -> raise (Eio.Cancel.Cancelled (Failure "z")))
   with
   | Eio.Cancel.Cancelled _ -> reraised := true);
  check bool "observe re-raises Cancelled" true !reraised

let test_observe_isolates_fiber_all_siblings () =
  (* Regression for the dashboard payload isolation
     (server_dashboard_http_core.dashboard_shell_payload_json): each parallel
     section is wrapped in [Cancel_safe.observe] so one section's failure does
     not cancel its siblings. In a bare [Eio.Fiber.all] a single fiber raising
     cancels the whole group; [observe] routes the non-Cancelled exception to
     [on_exn], so the failing fiber returns normally and the sibling fibers
     run to completion. *)
  Eio_main.run
  @@ fun _env ->
  let a = ref false in
  let c = ref false in
  let failures = ref 0 in
  Eio.Fiber.all
    [ (fun () ->
        Cancel_safe.observe ~on_exn:(fun _ -> incr failures) (fun () -> a := true))
    ; (fun () ->
        Cancel_safe.observe
          ~on_exn:(fun _ -> incr failures)
          (fun () -> raise (Failure "section b")))
    ; (fun () ->
        Cancel_safe.observe ~on_exn:(fun _ -> incr failures) (fun () -> c := true))
    ];
  check bool "sibling a completed despite section b failing" true !a;
  check bool "sibling c completed despite section b failing" true !c;
  check int "exactly one section routed to on_exn" 1 !failures

(* ---- is_internal_race_cancel: context-based, not rendering-based (#49742) ---- *)

(* The loser of a real [Fiber.first] captures its own cancellation; the owner,
   whose context is still live, recognises it as an internal race cancel. *)
let test_race_loser_is_internal () =
  Eio_main.run
  @@ fun _env ->
  let captured = ref None in
  let winner =
    Eio.Fiber.first
      (fun () -> 1)
      (fun () ->
        try Eio.Fiber.await_cancel ()
        with Eio.Cancel.Cancelled _ as e ->
          captured := Some e;
          raise e)
  in
  check int "first branch won" 1 winner;
  match !captured with
  | None -> fail "the losing branch was never cancelled"
  | Some e ->
    check bool "loser's Cancelled is an internal race cancel" true
      (Cancel_safe.is_internal_race_cancel e)

exception Stop

(* A fiber cancelled through its own switch sees [Cancelled] while its context
   is already off: that is the surrounding switch, not an inner race. *)
let test_own_switch_cancel_is_not_internal () =
  Eio_main.run
  @@ fun _env ->
  let verdict = ref None in
  (try
     Eio.Switch.run (fun sw ->
       Eio.Fiber.fork ~sw (fun () ->
         try Eio.Fiber.await_cancel ()
         with Eio.Cancel.Cancelled _ as e ->
           verdict := Some (Cancel_safe.is_internal_race_cancel e);
           raise e);
       Eio.Switch.fail sw Stop)
   with Stop -> ());
  match !verdict with
  | None -> fail "the forked fiber was never cancelled"
  | Some v -> check bool "own-switch Cancelled is not an internal race cancel" false v

let test_non_cancelled_is_not_internal () =
  check bool "Failure is not a race cancel" false
    (Cancel_safe.is_internal_race_cancel (Failure "Eio__core__Fiber.Not_first"))

let () =
  run "cancel_safe"
    [ ( "protect"
      , [ test_case "re-raises Cancelled" `Quick test_reraises_cancelled
        ; test_case "routes other exn to on_exn" `Quick test_routes_other_exn
        ; test_case "passes through success" `Quick test_passes_through_success
        ; test_case "observe routes then re-raises Cancelled" `Quick
            test_observe_routes_then_reraises
        ] )
    ; ( "fiber-all isolation"
      , [ test_case "observe lets Fiber.all siblings complete" `Quick
            test_observe_isolates_fiber_all_siblings
        ] )
    ; ( "is_internal_race_cancel"
      , [ test_case "Fiber.first loser is internal" `Quick test_race_loser_is_internal
        ; test_case "own-switch cancel is not internal" `Quick
            test_own_switch_cancel_is_not_internal
        ; test_case "non-Cancelled is not internal" `Quick
            test_non_cancelled_is_not_internal
        ] )
    ]
