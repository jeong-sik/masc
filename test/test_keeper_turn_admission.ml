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

let token_testable =
  Alcotest.testable
    (fun fmt token -> Format.fprintf fmt "<token %d>" (A.token_id token))
    (fun a b -> A.token_id a = A.token_id b)
;;

let acquire_token ?(channel = "test") ~limit ~keeper_name () =
  match
    A.acquire_turn
      ~limit
      ~timeout_s:0.0
      ~keeper_name
      ~runtime_profile:"test"
      ~channel
      ()
  with
  | Ok (token, _) -> token
  | Error rejection ->
    Alcotest.failf
      "unexpected rejection for %s: %s"
      keeper_name
      (A.rejection_to_string rejection)
;;

let acquire_result ?(channel = "test") ~limit ~keeper_name () =
  A.acquire_turn
    ~limit
    ~timeout_s:0.0
    ~keeper_name
    ~runtime_profile:"test"
    ~channel
    ()
;;

let test_acquire_times_out_at_limit () =
  A.reset_for_test ();
  let token =
    match acquire_result ~limit:1 ~keeper_name:"limit-a" () with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "first acquire: unexpected rejection %s"
        (A.rejection_to_string rejection)
  in
  Alcotest.(check (result (pair token_testable int) rejection))
    "second acquire rejected at cap"
    (Error A.Global_inflight_exceeded)
    (acquire_result ~limit:1 ~keeper_name:"limit-b" ());
  A.release_turn token;
  check_snapshot ~limit:1 ~state:"running" ~inflight:0

let test_pause_and_stop_reject_without_incrementing () =
  A.reset_for_test ();
  ignore (A.pause_fleet () : A.fleet_policy);
  Alcotest.(check (result (pair token_testable int) rejection))
    "paused rejected"
    (Error A.Fleet_paused)
    (acquire_result ~limit:1 ~keeper_name:"paused" ());
  check_snapshot ~limit:1 ~state:"paused" ~inflight:0;
  ignore (A.stop_fleet () : A.fleet_policy);
  Alcotest.(check (result (pair token_testable int) rejection))
    "stopped rejected"
    (Error A.Fleet_stopped)
    (acquire_result ~limit:1 ~keeper_name:"stopped" ());
  check_snapshot ~limit:1 ~state:"stopped" ~inflight:0;
  A.reset_for_test ()

let test_per_keeper_isolation_does_not_block_other_keeper () =
  A.reset_for_test ();
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let first_a = acquire_token ~limit:2 ~keeper_name:"keeper-a" () in
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
  let keeper_b = acquire_token ~limit:2 ~keeper_name:"keeper-b" () in
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
  let token = acquire_token ~limit:1 ~keeper_name:"keeper-stop" () in
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

let test_cancelled_waiter_is_removed_from_queue () =
  A.reset_for_test ();
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let held = acquire_token ~limit:1 ~keeper_name:"held" () in
  let waiter_switch_p, waiter_switch_u = Eio.Promise.create () in
  let waiter_done_p, waiter_done_u = Eio.Promise.create () in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
    let resolve_once outcome =
      match Eio.Promise.peek waiter_done_p with
      | None -> Eio.Promise.resolve waiter_done_u outcome
      | Some _ -> ()
    in
    try
      Eio.Switch.run (fun waiter_sw ->
        Eio.Promise.resolve waiter_switch_u waiter_sw;
        ignore
          (A.acquire_turn
             ~limit:1
             ~timeout_s:60.0
             ~keeper_name:"queued"
             ~runtime_profile:"test"
             ~channel:"test"
             ());
        resolve_once `Returned)
    with
    | Eio.Cancel.Cancelled _ -> resolve_once `Cancelled
    | exn -> resolve_once (`Raised (Printexc.to_string exn)));
  let waiter_sw = Eio.Promise.await waiter_switch_p in
  Eio.Time.sleep clock 0.01;
  Alcotest.(check int)
    "waiter queued before cancellation"
    1
    (A.snapshot ~limit:1 ()).queue_depth;
  Eio.Switch.fail waiter_sw Exit;
  (match Eio.Promise.await waiter_done_p with
   | `Cancelled -> ()
   | `Raised _ -> ()
   | `Returned -> Alcotest.fail "cancelled waiter unexpectedly returned");
  Alcotest.(check int)
    "cancelled waiter removed"
    0
    (A.snapshot ~limit:1 ()).queue_depth;
  A.release_turn held;
  Alcotest.(check int) "cancel cleanup did not leak token" 0 (A.global_inflight ());
  A.reset_for_test ()

let test_reactive_admitted_when_autonomous_channel_is_full () =
  A.reset_for_test ();
  let limit = 17 in
  let rec acquire_autonomous idx tokens =
    if idx = 16
    then tokens
    else
      acquire_autonomous
        (idx + 1)
        (acquire_token
           ~limit
           ~keeper_name:(Printf.sprintf "auto-%02d" idx)
           ~channel:"scheduled_autonomous"
           ()
         :: tokens)
  in
  let tokens = acquire_autonomous 0 [] in
  Alcotest.(check int) "global spare remains" 16 (A.global_inflight ());
  Alcotest.(check (result (pair token_testable int) rejection))
    "autonomous channel cap rejects one more autonomous turn"
    (Error A.Global_inflight_exceeded)
    (acquire_result
       ~limit
       ~keeper_name:"auto-extra"
       ~channel:"scheduled_autonomous"
       ());
  let reactive =
    match
      acquire_result ~limit ~keeper_name:"reactive-spare" ~channel:"reactive" ()
    with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "reactive turn should use global spare capacity: %s"
        (A.rejection_to_string rejection)
  in
  A.release_turn reactive;
  List.iter A.release_turn tokens;
  check_snapshot ~limit ~state:"running" ~inflight:0

let test_with_turn_admission_releases_on_success () =
  A.reset_for_test ();
  Eio_main.run @@ fun _env ->
  (match
     A.with_turn_admission
       ~keeper_name:"wrapper-success"
       ~runtime_profile:"test"
       ~channel:Masc.Keeper_world_observation.Reactive
       (fun ~semaphore_wait_ms ->
          Alcotest.(check bool) "wait ms non-negative" true (semaphore_wait_ms >= 0))
   with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) -> Alcotest.fail "unexpected wait timeout"
   | Error (`Turn_admission_rejected rejection) ->
     Alcotest.failf
       "unexpected admission rejection: %s"
       (A.rejection_to_string rejection));
  Alcotest.(check int) "wrapper released token" 0 (A.global_inflight ());
  A.reset_for_test ()

let test_force_release_releases_with_turn_admission_token () =
  A.reset_for_test ();
  (match
     A.with_turn_admission
       ~keeper_name:"wrapper-force"
       ~runtime_profile:"test"
       ~channel:Masc.Keeper_world_observation.Reactive
       (fun ~semaphore_wait_ms:_ ->
          Alcotest.(check int) "wrapper token registered" 1 (A.global_inflight ());
          Alcotest.(check bool)
            "force release finds wrapper token"
            true
            (A.force_release_keeper ~keeper_name:"wrapper-force");
          Alcotest.(check int) "force release drops token" 0 (A.global_inflight ()))
   with
   | Ok () -> ()
   | Error (`Semaphore_wait_timeout _) -> Alcotest.fail "unexpected wait timeout"
   | Error (`Turn_admission_rejected rejection) ->
     Alcotest.failf
       "unexpected admission rejection: %s"
       (A.rejection_to_string rejection));
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
        ; Alcotest.test_case
            "cancelled waiter is removed from queue"
            `Quick
            test_cancelled_waiter_is_removed_from_queue
        ; Alcotest.test_case
            "reactive admitted when autonomous channel is full"
            `Quick
            test_reactive_admitted_when_autonomous_channel_is_full
        ; Alcotest.test_case
            "with_turn_admission releases on success"
            `Quick
            test_with_turn_admission_releases_on_success
        ; Alcotest.test_case
            "force release drops with_turn_admission token"
            `Quick
            test_force_release_releases_with_turn_admission_token
        ] )
    ]
