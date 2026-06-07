(** Regression tests for central runtime admission plus per-keeper lanes.

    V1 has one central resource, [Runtime_turn]. Keeper-local ordering stays in
    [Keeper_turn_slot]; the central lease is acquired only after the keeper's
    own lane and channel slot are admitted. *)

module KK = Masc.Keeper_keepalive
module KTA = Masc.Keeper_turn_admission
module KTS = Masc.Keeper_turn_slot

let reactive = Masc.Keeper_world_observation.Reactive

exception Injected_body_failure

let assert_eq ~msg ~expected ~actual =
  if expected <> actual
  then failwith (Printf.sprintf "%s: expected=%d actual=%d" msg expected actual)
;;

let with_fresh_state ?(runtime_turn_limit = 32) body () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  KK.set_after_acquire_flag_hook_for_test None;
  KK.clear_force_released_markers_for_test ();
  KK.reset_autonomous_completion_for_test ();
  KK.reset_autonomous_turn_queue_for_test ();
  KTA.reset_for_test ~runtime_turn_limit ();
  Fun.protect
    ~finally:(fun () -> KTA.reset_for_test ())
    body
;;

let expect_ok_setup_lease ~keeper_name =
  match KTA.acquire_runtime_turn_lease ~keeper_name ~channel:reactive () with
  | Ok () -> ()
  | Error err ->
    failwith
      (Printf.sprintf
         "failed to acquire setup runtime lease: %s"
         (KTA.admission_error_to_string err))
;;

let test_runtime_limit_caps_distinct_keepers () =
  expect_ok_setup_lease ~keeper_name:"admission-holder";
  Fun.protect
    ~finally:KTA.release_runtime_turn_lease
    (fun () ->
       assert_eq
         ~msg:"setup lease consumes one runtime turn"
         ~expected:1
         ~actual:(KTA.runtime_turn_inflight ());
       let result =
         KTS.with_keeper_turn_slot_admission
           ~keeper_name:"admission-candidate"
           ~channel:reactive
           (fun ~semaphore_wait_ms:_ ->
              failwith "runtime capacity failure should happen before body")
       in
       match result with
       | Error (`Runtime_capacity_exceeded snapshot) ->
         assert_eq
           ~msg:"snapshot records configured runtime limit"
           ~expected:1
           ~actual:snapshot.KTA.runtime_limit;
         assert_eq
           ~msg:"snapshot records current runtime inflight"
           ~expected:1
           ~actual:snapshot.KTA.runtime_inflight;
         assert_eq
           ~msg:"failed admission does not consume another lease"
           ~expected:1
           ~actual:(KTA.runtime_turn_inflight ())
       | Error `Fleet_paused -> failwith "unexpected fleet paused"
       | Error `Fleet_stopped -> failwith "unexpected fleet stopped"
       | Error (`Semaphore_wait_timeout _) -> failwith "unexpected local slot timeout"
       | Ok () -> failwith "runtime capacity failure should reject candidate")
;;

let test_fleet_pause_and_stop_do_not_consume_runtime () =
  KTA.pause_fleet_admission ();
  let paused =
    KTS.with_keeper_turn_slot_admission
      ~keeper_name:"paused-keeper"
      ~channel:reactive
      (fun ~semaphore_wait_ms:_ -> failwith "paused fleet should skip body")
  in
  (match paused with
   | Error `Fleet_paused -> ()
   | Error err ->
     failwith
       (Printf.sprintf
          "expected Fleet_paused, got %s"
          (match err with
           | `Fleet_stopped -> "Fleet_stopped"
           | `Runtime_capacity_exceeded _ -> "Runtime_capacity_exceeded"
           | `Semaphore_wait_timeout _ -> "Semaphore_wait_timeout"
           | `Fleet_paused -> "Fleet_paused"))
   | Ok () -> failwith "paused fleet should reject admission");
  assert_eq
    ~msg:"paused fleet does not consume runtime lease"
    ~expected:0
    ~actual:(KTA.runtime_turn_inflight ());
  KTA.reset_for_test ();
  KTA.stop_fleet_admission ();
  let stopped =
    KTS.with_keeper_turn_slot_admission
      ~keeper_name:"stopped-keeper"
      ~channel:reactive
      (fun ~semaphore_wait_ms:_ -> failwith "stopped fleet should skip body")
  in
  (match stopped with
   | Error `Fleet_stopped -> ()
   | Error _ -> failwith "expected Fleet_stopped"
   | Ok () -> failwith "stopped fleet should reject admission");
  assert_eq
    ~msg:"stopped fleet does not consume runtime lease"
    ~expected:0
    ~actual:(KTA.runtime_turn_inflight ())
;;

let test_same_keeper_lane_waits_before_runtime_lease () =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  let clock = Eio.Stdenv.clock env in
  KK.set_after_acquire_flag_hook_for_test None;
  KK.clear_force_released_markers_for_test ();
  KK.reset_autonomous_completion_for_test ();
  KK.reset_autonomous_turn_queue_for_test ();
  KTA.reset_for_test ~runtime_turn_limit:2 ();
  Eio.Switch.run (fun sw ->
    let first_entered, resolve_first_entered = Eio.Promise.create () in
    let release_first, resolve_release_first = Eio.Promise.create () in
    let second_entered, resolve_second_entered = Eio.Promise.create () in
    let second_done, resolve_second_done = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      match
        KTS.with_keeper_turn_slot_admission
          ~keeper_name:"same-keeper-lane"
          ~channel:reactive
          (fun ~semaphore_wait_ms:_ ->
             Eio.Promise.resolve resolve_first_entered ();
             Eio.Promise.await release_first)
      with
      | Ok () -> ()
      | Error _ -> failwith "first same-keeper admission unexpectedly failed");
    Eio.Promise.await first_entered;
    assert_eq
      ~msg:"first keeper turn holds one runtime lease"
      ~expected:1
      ~actual:(KTA.runtime_turn_inflight ());
    Eio.Fiber.fork ~sw (fun () ->
      let result =
        KTS.with_keeper_turn_slot_admission
          ~keeper_name:"same-keeper-lane"
          ~channel:reactive
          (fun ~semaphore_wait_ms:_ ->
             Eio.Promise.resolve resolve_second_entered ())
      in
      Eio.Promise.resolve resolve_second_done result);
    Eio.Time.sleep clock 0.02;
    (match Eio.Promise.peek second_entered with
     | None -> ()
     | Some () -> failwith "second same-keeper turn entered before first released");
    assert_eq
      ~msg:"same keeper waits in local lane before consuming runtime lease"
      ~expected:1
      ~actual:(KTA.runtime_turn_inflight ());
    Eio.Promise.resolve resolve_release_first ();
    match Eio.Promise.await second_done with
    | Ok () -> ()
    | Error _ -> failwith "second same-keeper admission unexpectedly failed");
  assert_eq
    ~msg:"same keeper lane releases all runtime leases"
    ~expected:0
    ~actual:(KTA.runtime_turn_inflight ());
  KTA.reset_for_test ()
;;

let test_runtime_lease_released_when_body_raises () =
  (try
     ignore
       (KTS.with_keeper_turn_slot_admission
          ~keeper_name:"raising-keeper"
          ~channel:reactive
          (fun ~semaphore_wait_ms:_ ->
             assert_eq
               ~msg:"body holds runtime lease"
               ~expected:1
               ~actual:(KTA.runtime_turn_inflight ());
             raise Injected_body_failure));
     failwith "expected injected body failure"
   with
   | Injected_body_failure -> ());
  assert_eq
    ~msg:"runtime lease released after body exception"
    ~expected:0
    ~actual:(KTA.runtime_turn_inflight ())
;;

let () =
  let cases =
    [ ( "runtime limit caps distinct keepers"
      , with_fresh_state ~runtime_turn_limit:1 test_runtime_limit_caps_distinct_keepers )
    ; ( "fleet pause and stop reject without consuming runtime"
      , with_fresh_state test_fleet_pause_and_stop_do_not_consume_runtime )
    ; ( "same keeper waits in local lane before runtime lease"
      , test_same_keeper_lane_waits_before_runtime_lease )
    ; ( "runtime lease released when body raises"
      , with_fresh_state ~runtime_turn_limit:1 test_runtime_lease_released_when_body_raises
      )
    ]
  in
  List.iter
    (fun (name, body) ->
       try
         body ();
         Printf.printf "ok   %s\n" name
       with exn ->
         Printf.printf "FAIL %s: %s\n" name (Printexc.to_string exn);
         exit 1)
    cases
;;
