(** test_keeper_lifecycle_hooks — RFC-0036 Phase A.1 plumbing tests.

    Verifies the additive hook registry contract:
    - register adds; registered_count reflects size
    - run dispatches in registration order
    - exception in one hook does not stop later hooks or raise out
    - reset_for_testing clears state between cases *)

open Alcotest

module H = Masc_mcp.Keeper_lifecycle_hooks
module P = Masc_mcp.Prometheus
module SM = Masc_mcp.Keeper_state_machine

let setup () = H.reset_for_testing ()

let lifecycle_hook_failure_count ~keeper =
  P.metric_value_or_zero
    P.metric_keeper_lifecycle_callback_failures
    ~labels:
      [
        ("keeper", keeper);
        ("callback", "keeper_lifecycle_hook");
      ]
    ()

let test_register_increments_count () =
  setup ();
  check int "starts empty" 0 (H.registered_count ());
  H.register (fun ~keeper_id:_ _ -> ());
  check int "one after register" 1 (H.registered_count ());
  H.register (fun ~keeper_id:_ _ -> ());
  check int "two after second register" 2 (H.registered_count ())

let test_run_dispatches_in_order () =
  setup ();
  let order = ref [] in
  H.register (fun ~keeper_id:_ _ -> order := "a" :: !order);
  H.register (fun ~keeper_id:_ _ -> order := "b" :: !order);
  H.register (fun ~keeper_id:_ _ -> order := "c" :: !order);
  H.run ~keeper_id:"k1" H.Tombstone_reaped;
  (* List was prepended, so reverse to get registration order *)
  check (list string) "registration order" [ "a"; "b"; "c" ]
    (List.rev !order)

let test_run_passes_keeper_id_and_event () =
  setup ();
  let captured = ref [] in
  H.register (fun ~keeper_id ev ->
    let tag = match ev with
      | H.Tombstone_reaped -> "tombstone"
      | H.Phase_transition { from_phase; to_phase } ->
        Printf.sprintf "%s->%s"
          (SM.phase_to_string from_phase)
          (SM.phase_to_string to_phase)
    in
    captured := (keeper_id, tag) :: !captured);
  H.run ~keeper_id:"alpha" H.Tombstone_reaped;
  H.run ~keeper_id:"beta"
    (H.Phase_transition
       { from_phase = SM.Running; to_phase = SM.Dead });
  let want = [
    ("alpha", "tombstone");
    ("beta",  "running->dead");
  ] in
  check (list (pair string string)) "captured events" want
    (List.rev !captured)

let test_exception_in_hook_is_swallowed () =
  setup ();
  let keeper = "keeper-lifecycle-hooks-test" in
  let after_count = ref 0 in
  H.register (fun ~keeper_id:_ _ -> failwith "boom");
  H.register (fun ~keeper_id:_ _ -> incr after_count);
  let before = lifecycle_hook_failure_count ~keeper in
  (* Should not raise. *)
  H.run ~keeper_id:keeper H.Tombstone_reaped;
  let after = lifecycle_hook_failure_count ~keeper in
  check int "subsequent hook still ran" 1 !after_count;
  check (float 0.001) "hook failure metric increments" 1.0
    (after -. before)

let test_cancelled_in_hook_is_reraised () =
  setup ();
  H.register (fun ~keeper_id:_ _ ->
    raise (Eio.Cancel.Cancelled (Failure "synthetic cancel")));
  let raised =
    try
      H.run ~keeper_id:"cancel-keeper" H.Tombstone_reaped;
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  check bool "cancelled re-raised" true raised

let test_reset_for_testing_clears () =
  setup ();
  H.register (fun ~keeper_id:_ _ -> ());
  H.register (fun ~keeper_id:_ _ -> ());
  check int "two registered" 2 (H.registered_count ());
  H.reset_for_testing ();
  check int "cleared" 0 (H.registered_count ())

let () =
  run "Keeper_lifecycle_hooks" [
    "register",      [ test_case "increments count" `Quick test_register_increments_count ];
    "run",           [
      test_case "dispatches in order"        `Quick test_run_dispatches_in_order;
      test_case "passes keeper_id and event" `Quick test_run_passes_keeper_id_and_event;
      test_case "swallows exceptions"        `Quick test_exception_in_hook_is_swallowed;
      test_case "re-raises cancellation"     `Quick test_cancelled_in_hook_is_reraised;
    ];
    "reset_for_testing", [ test_case "clears all" `Quick test_reset_for_testing_clears ];
  ]
