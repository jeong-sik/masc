(** Negative / edge-case tests for Keeper_transition_audit.
    These cover the paths that PR #9686 added but didn't test. *)

open Alcotest

module Audit = Masc_mcp.Keeper_transition_audit

let fail = Alcotest.fail

(* ── Helpers to exercise the JSON round-trip via store ─────────── *)

let test_recent_completed_turns_empty_store () =
  Audit.For_testing.reset_state ();
  let turns = Audit.recent_completed_turns ~keeper_name:"never-seen" ~limit:5 in
  check int "empty store returns []" 0 (List.length turns)

let test_record_and_read_multiple_turns () =
  Audit.For_testing.reset_state ();
  let keeper_name = "multi-turn-keeper" in
  for i = 1 to 3 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int (i * 10);
        ended_at = float_of_int (i * 10 + 5);
        outcome = Audit.Turn_failed;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:5 in
  check int "3 turns recorded" 3 (List.length turns);
  List.iteri
    (fun idx turn ->
      let expected_id = 3 - idx in
      check int (Printf.sprintf "turn %d id" idx) expected_id turn.Audit.turn_id)
    turns

let test_ring_capacity_limit () =
  Audit.For_testing.reset_state ();
  let keeper_name = "capacity-keeper" in
  for i = 1 to 55 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int i;
        ended_at = float_of_int (i + 1);
        outcome = Audit.Turn_gate_rejected;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:100 in
  check int "ring capacity caps at 50" 50 (List.length turns);
  (* newest should be 55, oldest in result should be 6 *)
  match turns with
  | newest :: _ -> check int "newest is 55" 55 newest.Audit.turn_id
  | [] -> fail "expected at least one turn"

let test_ring_ordering_is_newest_first () =
  Audit.For_testing.reset_state ();
  let keeper_name = "order-keeper" in
  Audit.record_completed_turn ~keeper_name
    { Audit.turn_id = 1; started_at = 1.0; ended_at = 2.0; outcome = Audit.Turn_substantive };
  Audit.record_completed_turn ~keeper_name
    { Audit.turn_id = 2; started_at = 3.0; ended_at = 4.0; outcome = Audit.Turn_failed };
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:2 in
  check int "first is newest" 2 (List.hd turns).Audit.turn_id;
  check int "second is older" 1 (List.nth turns 1).Audit.turn_id

let test_limit_respected () =
  Audit.For_testing.reset_state ();
  let keeper_name = "limit-keeper" in
  for i = 1 to 10 do
    Audit.record_completed_turn ~keeper_name
      {
        Audit.turn_id = i;
        started_at = float_of_int i;
        ended_at = float_of_int (i + 1);
        outcome = Audit.Turn_substantive;
      }
  done;
  let turns = Audit.recent_completed_turns ~keeper_name ~limit:3 in
  check int "limit respected" 3 (List.length turns);
  check int "newest within limit" 10 (List.hd turns).Audit.turn_id

(* ── Run ───────────────────────────────────────────────────────── *)

let () =
  run "Keeper_transition_audit"
    [
      ( "recent_completed_turns",
        [
          test_case "empty store" `Quick test_recent_completed_turns_empty_store;
          test_case "record and read multiple" `Quick test_record_and_read_multiple_turns;
          test_case "ring capacity limit" `Quick test_ring_capacity_limit;
          test_case "ring ordering newest first" `Quick test_ring_ordering_is_newest_first;
          test_case "limit respected" `Quick test_limit_respected;
        ] );
    ]
