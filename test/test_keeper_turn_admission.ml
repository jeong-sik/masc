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

let test_keeper_identity_is_not_an_admission_key () =
  A.reset_for_test ();
  let first_a = acquire_token ~limit:2 ~keeper_name:"keeper-a" () in
  let second_a = acquire_token ~limit:2 ~keeper_name:"keeper-a" () in
  Alcotest.(check int) "same keeper admitted up to runtime cap" 2 (A.global_inflight ());
  Alcotest.(check int) "admission has no waiter queue" 0 (A.snapshot ~limit:2 ()).queue_depth;
  Alcotest.(check (list string))
    "admission has no active-keeper index"
    []
    (A.snapshot ~limit:2 ()).active_keepers;
  A.release_turn first_a;
  A.release_turn second_a;
  check_snapshot ~limit:2 ~state:"running" ~inflight:0

let test_double_release_is_noop () =
  A.reset_for_test ();
  let token = acquire_token ~limit:1 ~keeper_name:"double-release" () in
  Alcotest.(check int) "lease acquired" 1 (A.global_inflight ());
  A.release_turn token;
  A.release_turn token;
  Alcotest.(check int) "second release is a no-op" 0 (A.global_inflight ());
  A.reset_for_test ()

let test_stop_does_not_cancel_inflight_tokens () =
  A.reset_for_test ();
  let token = acquire_token ~limit:1 ~keeper_name:"keeper-stop" () in
  Alcotest.(check bool)
    "cancel promise initially unresolved"
    true
    (Option.is_none (Eio.Promise.peek (A.token_cancel_p token)));
  ignore (A.stop_fleet () : A.fleet_policy);
  Alcotest.(check bool)
    "stop does not own in-flight cancellation"
    true
    (Option.is_none (Eio.Promise.peek (A.token_cancel_p token)));
  Alcotest.(check int) "in-flight lease remains until release" 1 (A.global_inflight ());
  A.release_turn token;
  A.reset_for_test ()

let test_force_release_resolves_token_cancel_p () =
  A.reset_for_test ();
  let token = acquire_token ~limit:1 ~keeper_name:"force-cancel" () in
  Alcotest.(check bool)
    "cancel promise initially unresolved"
    true
    (Option.is_none (Eio.Promise.peek (A.token_cancel_p token)));
  Alcotest.(check bool)
    "force release finds token"
    true
    (A.force_release_keeper ~keeper_name:"force-cancel");
  Alcotest.(check bool)
    "force release resolves cancel promise"
    true
    (Option.is_some (Eio.Promise.peek (A.token_cancel_p token)));
  Alcotest.(check int) "force release drops token" 0 (A.global_inflight ());
  A.reset_for_test ()

let test_capacity_rejection_does_not_queue_waiters () =
  A.reset_for_test ();
  let held = acquire_token ~limit:1 ~keeper_name:"held" () in
  Alcotest.(check (result (pair token_testable int) rejection))
    "over capacity rejected immediately"
    (Error A.Global_inflight_exceeded)
    (acquire_result ~limit:1 ~keeper_name:"not-queued" ());
  Alcotest.(check int)
    "no waiter queue retained"
    0
    (A.snapshot ~limit:1 ()).queue_depth;
  A.release_turn held;
  Alcotest.(check int) "capacity rejection did not leak token" 0 (A.global_inflight ());
  A.reset_for_test ()

let test_channels_share_runtime_capacity () =
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
  let last_autonomous =
    match
      acquire_result ~limit ~keeper_name:"auto-extra" ~channel:"scheduled_autonomous" ()
    with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "scheduled turn should use the remaining runtime capacity: %s"
        (A.rejection_to_string rejection)
  in
  Alcotest.(check (result (pair token_testable int) rejection))
    "reactive channel has no private spare beyond runtime cap"
    (Error A.Global_inflight_exceeded)
    (acquire_result ~limit ~keeper_name:"reactive-extra" ~channel:"reactive" ());
  A.release_turn last_autonomous;
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

let test_fake_llm_turn_holds_admission_until_callback_finishes () =
  A.reset_for_test ();
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let started_p, started_u = Eio.Promise.create () in
  let release_p, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    match
      A.with_turn_admission
        ~keeper_name:"fake-llm-a"
        ~runtime_profile:"fake-llm"
        ~channel:Masc.Keeper_world_observation.Reactive
        (fun ~semaphore_wait_ms:_ ->
           Eio.Promise.resolve started_u ();
           Eio.Promise.await release_p)
    with
    | Ok () -> ()
    | Error (`Semaphore_wait_timeout _) ->
      Alcotest.fail "fake llm turn hit unexpected wait timeout"
    | Error (`Turn_admission_rejected rejection) ->
      Alcotest.failf
        "fake llm turn hit unexpected rejection: %s"
        (A.rejection_to_string rejection));
  Eio.Promise.await started_p;
  Alcotest.(check int) "fake llm callback holds one token" 1 (A.global_inflight ());
  let same_keeper_second =
    match
      A.acquire_turn
        ~limit:2
        ~timeout_s:0.0
        ~keeper_name:"fake-llm-a"
        ~runtime_profile:"fake-llm"
        ~channel:"test"
        ()
    with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "same keeper identity is not an admission key: %s"
        (A.rejection_to_string rejection)
  in
  A.release_turn same_keeper_second;
  let other_keeper =
    match
      A.acquire_turn
        ~limit:2
        ~timeout_s:0.0
        ~keeper_name:"fake-llm-b"
        ~runtime_profile:"fake-llm"
        ~channel:"test"
        ()
    with
    | Ok (token, _) -> token
    | Error rejection ->
      Alcotest.failf
        "different keeper should be admitted while fake llm is running: %s"
        (A.rejection_to_string rejection)
  in
  Alcotest.(check int) "different keeper admitted concurrently" 2 (A.global_inflight ());
  A.release_turn other_keeper;
  Eio.Promise.resolve release_u ();
  let rec wait_until_released attempts =
    if A.global_inflight () = 0
    then ()
    else if attempts = 0
    then
      Alcotest.failf
        "fake llm callback did not release token; inflight=%d"
        (A.global_inflight ())
    else (
      Eio.Fiber.yield ();
      Eio.Time.sleep clock 0.01;
      wait_until_released (attempts - 1))
  in
  wait_until_released 20;
  A.reset_for_test ()

let test_force_release_cancels_with_turn_admission_token () =
  A.reset_for_test ();
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let started_p, started_u = Eio.Promise.create () in
  let result = ref None in
  Eio.Fiber.fork ~sw (fun () ->
    let observed =
      try
        match
          A.with_turn_admission
            ~keeper_name:"wrapper-force"
            ~runtime_profile:"test"
            ~channel:Masc.Keeper_world_observation.Reactive
            (fun ~semaphore_wait_ms:_ ->
               Eio.Promise.resolve started_u ();
               Eio.Time.sleep clock 60.0)
        with
        | Ok () -> "completed"
        | Error (`Semaphore_wait_timeout _) -> "wait_timeout"
        | Error (`Turn_admission_rejected rejection) ->
          "rejected:" ^ A.rejection_to_string rejection
      with
      | A.Fleet_stopped_by_operator -> "fleet_stopped"
    in
    result := Some observed);
  Eio.Promise.await started_p;
  Alcotest.(check int) "wrapper token registered" 1 (A.global_inflight ());
  Alcotest.(check bool)
    "force release finds wrapper token"
    true
    (A.force_release_keeper ~keeper_name:"wrapper-force");
  let rec wait_for_result attempts =
    match !result with
    | Some observed -> observed
    | None when attempts <= 0 -> Alcotest.fail "force release did not cancel wrapper turn"
    | None ->
      Eio.Fiber.yield ();
      Eio.Time.sleep clock 0.01;
      wait_for_result (attempts - 1)
  in
  Alcotest.(check string)
    "force release interrupts wrapper turn"
    "fleet_stopped"
    (wait_for_result 100);
  Alcotest.(check int) "force release drops token" 0 (A.global_inflight ());
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
            "keeper identity is not an admission key"
            `Quick
            test_keeper_identity_is_not_an_admission_key
        ; Alcotest.test_case
            "double release is a no-op"
            `Quick
            test_double_release_is_noop
        ; Alcotest.test_case
            "stop does not cancel inflight tokens"
            `Quick
            test_stop_does_not_cancel_inflight_tokens
        ; Alcotest.test_case
            "force release resolves token cancel promise"
            `Quick
            test_force_release_resolves_token_cancel_p
        ; Alcotest.test_case
            "capacity rejection does not queue waiters"
            `Quick
            test_capacity_rejection_does_not_queue_waiters
        ; Alcotest.test_case
            "channels share runtime capacity"
            `Quick
            test_channels_share_runtime_capacity
        ; Alcotest.test_case
            "with_turn_admission releases on success"
            `Quick
            test_with_turn_admission_releases_on_success
        ; Alcotest.test_case
            "fake llm turn holds admission until callback finishes"
            `Quick
            test_fake_llm_turn_holds_admission_until_callback_finishes
        ; Alcotest.test_case
            "force release cancels with_turn_admission token"
            `Quick
            test_force_release_cancels_with_turn_admission_token
        ] )
    ]
