module A = Masc.Keeper_turn_admission

let rejection =
  Alcotest.testable
    (fun fmt rejection -> Format.pp_print_string fmt (A.rejection_to_string rejection))
    ( = )
;;

let check_snapshot ~limit ~state ~inflight =
  let snapshot = A.snapshot ~limit () in
  Alcotest.(check string)
    "fleet state"
    state
    (A.fleet_state_to_string snapshot.fleet_state);
  Alcotest.(check int) "global inflight" inflight snapshot.global_inflight;
  Alcotest.(check int) "global limit" limit snapshot.global_limit
;;

let check_acquire_ok label result =
  match result with
  | Ok _ -> ()
  | Error rejection ->
    Alcotest.failf "%s: unexpected rejection %s" label (A.rejection_to_string rejection)
;;

let acquire_token ~limit ~keeper_name =
  match
    A.acquire_turn
      ~limit
      ~timeout_s:0.0
      ~keeper_name
      ~runtime_profile:"test"
      ~channel:"test"
      ()
  with
  | Ok (token, _) -> token
  | Error rejection ->
    Alcotest.failf
      "unexpected rejection for %s: %s"
      keeper_name
      (A.rejection_to_string rejection)
;;

let test_acquire_times_out_at_limit () =
  A.reset_for_test ();
  check_acquire_ok "first acquire" (A.acquire_global_slot ~limit:1 ~timeout_s:0.0 ());
  Alcotest.(check (result int rejection))
    "second acquire rejected at cap"
    (Error A.Global_inflight_exceeded)
    (A.acquire_global_slot ~limit:1 ~timeout_s:0.0 ());
  A.release_global_slot ();
  check_snapshot ~limit:1 ~state:"running" ~inflight:0

let test_pause_and_stop_reject_without_incrementing () =
  A.reset_for_test ();
  ignore (A.pause_fleet () : A.fleet_policy);
  Alcotest.(check (result int rejection))
    "paused rejected"
    (Error A.Fleet_paused)
    (A.acquire_global_slot ~limit:1 ~timeout_s:0.0 ());
  check_snapshot ~limit:1 ~state:"paused" ~inflight:0;
  ignore (A.stop_fleet () : A.fleet_policy);
  Alcotest.(check (result int rejection))
    "stopped rejected"
    (Error A.Fleet_stopped)
    (A.acquire_global_slot ~limit:1 ~timeout_s:0.0 ());
  check_snapshot ~limit:1 ~state:"stopped" ~inflight:0;
  A.reset_for_test ()

let test_per_keeper_isolation_does_not_block_other_keeper () =
  A.reset_for_test ();
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let first_a = acquire_token ~limit:2 ~keeper_name:"keeper-a" in
  let waiter_done_p, waiter_done_u = Eio.Promise.create () in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    let outcome =
      A.acquire_turn
        ~limit:2
        ~timeout_s:1.0
        ~keeper_name:"keeper-a"
        ~runtime_profile:"test"
        ~channel:"test"
        ()
    in
    Eio.Promise.resolve waiter_done_u outcome);
  Eio.Time.sleep clock 0.01;
  let snapshot = A.snapshot ~limit:2 () in
  Alcotest.(check int) "same-keeper waiter queued" 1 snapshot.queue_depth;
  let keeper_b = acquire_token ~limit:2 ~keeper_name:"keeper-b" in
  Alcotest.(check int) "different keeper admitted" 2 (A.global_inflight ());
  A.release_turn first_a;
  let second_a =
    match Eio.Promise.await waiter_done_p with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "same keeper waiter was not admitted after release: %s"
        (A.rejection_to_string rejection)
  in
  A.release_turn second_a;
  A.release_turn keeper_b;
  check_snapshot ~limit:2 ~state:"running" ~inflight:0

let test_stop_cancels_inflight_tokens () =
  A.reset_for_test ();
  let token = acquire_token ~limit:1 ~keeper_name:"keeper-stop" in
  Alcotest.(check bool)
    "cancel promise initially unresolved"
    true
    (Option.is_none (Eio.Promise.peek (A.token_cancel_p token)));
  ignore (A.stop_fleet () : A.fleet_policy);
  Alcotest.(check bool)
    "cancel promise resolved by stop"
    true
    (Option.is_some (Eio.Promise.peek (A.token_cancel_p token)));
  A.release_turn token;
  A.reset_for_test ()

let () =
  Alcotest.run
    "keeper_turn_admission"
    [ ( "admission"
      , [ Alcotest.test_case
            "acquire times out at limit"
            `Quick
            test_acquire_times_out_at_limit
        ; Alcotest.test_case
            "pause and stop reject without incrementing"
            `Quick
            test_pause_and_stop_reject_without_incrementing
        ; Alcotest.test_case
            "per-keeper isolation does not block other keeper"
            `Quick
            test_per_keeper_isolation_does_not_block_other_keeper
        ; Alcotest.test_case
            "stop cancels inflight tokens"
            `Quick
            test_stop_cancels_inflight_tokens
        ] )
    ]
