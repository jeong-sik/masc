module F = Masc.Keeper_fleet_stop_switch

let reject =
  Alcotest.testable
    (fun fmt rejection -> Format.pp_print_string fmt (F.admission_error_to_string rejection))
    ( = )
;;

let check_state ~state ~inflight =
  let snapshot = F.snapshot () in
  Alcotest.(check string)
    "fleet state"
    (F.fleet_state_to_string state)
    (F.fleet_state_to_string snapshot.fleet_state);
  Alcotest.(check int) "global inflight" inflight snapshot.global_inflight
;;

let check_rejection label expected = function
  | Error actual ->
    Alcotest.(check string)
      label
      (F.admission_error_to_string expected)
      (F.admission_error_to_string actual)
  | Ok () -> Alcotest.failf "%s: expected rejection" label
;;

let test_pause_preserves_inflight_and_blocks_new_turns () =
  F.reset_for_test ();
  Alcotest.(check (result unit reject))
    "first acquire"
    (Ok ())
    (F.acquire_turn ~limit:2);
  F.pause_fleet ();
  check_state ~state:F.Paused ~inflight:1;
  check_rejection
    "paused acquire rejected"
    F.Fleet_paused
    (F.acquire_turn ~limit:2);
  F.release_turn ();
  check_state ~state:F.Paused ~inflight:0;
  F.resume_fleet ();
  check_state ~state:F.Running ~inflight:0

let test_stop_rejects_until_reset () =
  F.reset_for_test ();
  F.stop_fleet ();
  check_state ~state:F.Stopped ~inflight:0;
  check_rejection
    "stopped acquire rejected"
    F.Fleet_stopped
    (F.acquire_turn ~limit:1);
  F.reset_for_test ();
  check_state ~state:F.Running ~inflight:0

let test_global_limit_is_enforced () =
  F.reset_for_test ();
  Alcotest.(check (result unit reject)) "acquire 1" (Ok ()) (F.acquire_turn ~limit:1);
  check_rejection
    "second acquire rejected"
    F.Global_inflight_exceeded
    (F.acquire_turn ~limit:1);
  F.release_turn ();
  check_state ~state:F.Running ~inflight:0

let () =
  Alcotest.run
    "keeper_fleet_stop_switch"
    [ ( "fleet"
      , [ Alcotest.test_case
            "pause preserves inflight and blocks new turns"
            `Quick
            test_pause_preserves_inflight_and_blocks_new_turns
        ; Alcotest.test_case "stop rejects until reset" `Quick test_stop_rejects_until_reset
        ; Alcotest.test_case "global limit is enforced" `Quick test_global_limit_is_enforced
        ] )
    ]
