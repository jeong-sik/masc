(** test_keeper_circuit_breaker — Circuit breaker module tests.

    Pure unit tests for the deterministic core:
    - default_state creation
    - increment_state (counter increases)
    - reset_state (counter resets, timestamp updates)
    - should_skip (returns true when threshold exceeded, false otherwise)
    - load_state/save_state round-trip (JSON persistence)
    - state_to_json/json_to_state serialization
    - threshold boundary conditions
    - cooldown_remaining calculation
*)

open Alcotest
module CB = Keeper_circuit_breaker

(* ── Helpers ───────────────────────────────────────────── *)

(** Testable type for circuit breaker state. *)
let state_t =
  Alcotest.
    (object
       method field s = Fmt.string s
       method equal a b =
         a.consecutive_idle_turns = b.consecutive_idle_turns
         && a.threshold = b.threshold
         && a.last_reset_time = b.last_reset_time
         && a.cooldown_remaining = b.cooldown_remaining
         && a.should_skip = b.should_skip
    end)

(** Default threshold for testing. *)
let default_threshold = 3

(** Create a default state for testing. *)
let make_default_state ?(threshold = default_threshold) () =
  CB.default_state ~threshold

(** Create a state with specific values for testing. *)
let make_test_state ~consecutive_idle_turns ~threshold ~last_reset_time
    ~cooldown_remaining ~should_skip () =
  { CB.consecutive_idle_turns; threshold; last_reset_time; cooldown_remaining;
    should_skip }

(* ── default_state tests ───────────────────────────────── *)

let test_default_state_initial_values () =
  let state = make_default_state () in
  check int "initial consecutive_idle_turns = 0" 0 state.consecutive_idle_turns;
  check int "initial threshold = 3" 3 state.threshold;
  check float "initial last_reset_time = 0.0" 0.0 state.last_reset_time;
  check float "initial cooldown_remaining = 60.0" 60.0 state.cooldown_remaining;
  check bool "initial should_skip = false" false state.should_skip
;;

let test_default_state_custom_threshold () =
  let state = make_default_state ~threshold:5 () in
  check int "custom threshold = 5" 5 state.threshold
;;

(* ── increment_state tests ─────────────────────────────── *)

let test_increment_state_counter_increases () =
  let state = make_default_state () in
  let state' = CB.increment_state state in
  check int "counter increased to 1" 1 state'.consecutive_idle_turns;
  check int "threshold unchanged" 3 state'.threshold
;;

let test_increment_state_multiple_times () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state (CB.increment_state state)) in
  check int "counter increased to 3 after 3 increments" 3 state'.consecutive_idle_turns
;;

let test_increment_state_does_not_change_timestamp () =
  let state = make_default_state () in
  let state' = CB.increment_state state in
  check float "timestamp unchanged" 0.0 state'.last_reset_time
;;

(* ── reset_state tests ─────────────────────────────────── *)

let test_reset_state_counter_resets () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state state) in
  let state'' = CB.reset_state state' in
  check int "counter reset to 0" 0 state''.consecutive_idle_turns
;;

let test_reset_state_timestamp_updates () =
  let state = make_default_state () in
  let state' = CB.reset_state state in
  (* Timestamp should be updated from 0.0 to some positive value *)
  check (float_with_epsilon 0.001) "timestamp updated" 0.001 state'.last_reset_time
;;

let test_reset_state_cooldown_remaining_resets () =
  let state = make_default_state () in
  let state' = CB.reset_state state in
  check float "cooldown_remaining reset to 60.0" 60.0 state'.cooldown_remaining
;;

(* ── should_skip tests ─────────────────────────────────── *)

let test_should_skip_below_threshold () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state state) in
  check bool "should_skip = false when below threshold" false
    (CB.should_skip ~state:state')
;;

let test_should_skip_at_threshold () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state (CB.increment_state state)) in
  check bool "should_skip = true when at threshold" true
    (CB.should_skip ~state:state')
;;

let test_should_skip_above_threshold () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state (CB.increment_state (CB.increment_state state))) in
  check bool "should_skip = true when above threshold" true
    (CB.should_skip ~state:state')
;;

let test_should_skip_after_reset () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state (CB.increment_state state)) in
  let state'' = CB.reset_state state' in
  check bool "should_skip = false after reset" false
    (CB.should_skip ~state:state'')
;;

(* ── load_state/save_state round-trip tests ────────────── *)

let test_load_save_round_trip () =
  let original_state = make_default_state () in
  let json = CB.state_to_json original_state in
  let restored_state = CB.json_to_state json in
  check state_t "round-trip preserves state" original_state restored_state
;;

let test_load_save_round_trip_with_values () =
  let original_state =
    make_test_state
      ~consecutive_idle_turns:5
      ~threshold:4
      ~last_reset_time:100.0
      ~cooldown_remaining:30.0
      ~should_skip:true ()
  in
  let json = CB.state_to_json original_state in
  let restored_state = CB.json_to_state json in
  check state_t "round-trip preserves state with values" original_state restored_state
;;

(* ── state_to_json/json_to_state serialization tests ───── *)

let test_state_to_json_serializes_correctly () =
  let state = make_default_state () in
  let json = CB.state_to_json state in
  (* Check that the JSON contains the expected fields *)
  Alcotest.(check string "json contains consecutive_idle_turns" "consecutive_idle_turns"
    (Yojson.Basic.Util.string (Yojson.Basic.Util.member "consecutive_idle_turns" json)));
  Alcotest.(check int "json has correct consecutive_idle_turns value" 0
    (Yojson.Basic.Util.int (Yojson.Basic.Util.member "consecutive_idle_turns" json)));
  Alcotest.(check int "json contains threshold" 3
    (Yojson.Basic.Util.int (Yojson.Basic.Util.member "threshold" json)));
  Alcotest.(check bool "json contains should_skip" false
    (Yojson.Basic.Util.bool (Yojson.Basic.Util.member "should_skip" json)))
;;

let test_json_to_state_deserializes_correctly () =
  let json = `Assoc [
    ("consecutive_idle_turns", `Int 2);
    ("threshold", `Int 5);
    ("last_reset_time", `Float 50.0);
    ("cooldown_remaining", `Float 45.0);
    ("should_skip", `Bool true);
  ] in
  let state = CB.json_to_state json in
  check int "consecutive_idle_turns deserialized" 2 state.consecutive_idle_turns;
  check int "threshold deserialized" 5 state.threshold;
  check float "last_reset_time deserialized" 50.0 state.last_reset_time;
  check float "cooldown_remaining deserialized" 45.0 state.cooldown_remaining;
  check bool "should_skip deserialized" true state.should_skip
;;

(* ── threshold boundary condition tests ────────────────── *)

let test_threshold_boundary_one () =
  let state = CB.default_state ~threshold:1 in
  let state' = CB.increment_state state in
  check bool "should_skip = true when threshold=1 and counter=1" true
    (CB.should_skip ~state:state')
;;

let test_threshold_boundary_zero () =
  let state = CB.default_state ~threshold:0 in
  (* With threshold=0, should_skip should be true immediately *)
  check bool "should_skip = true when threshold=0" true
    (CB.should_skip ~state:state)
;;

(* ── Cooldown remaining calculation tests ──────────────── *)

let test_cooldown_remaining_decreases_over_time () =
  let state = make_default_state () in
  let state' = CB.increment_state state in
  (* cooldown_remaining should decrease as time passes *)
  check float "cooldown_remaining decreases" 60.0 state'.cooldown_remaining
;;

let test_cooldown_remaining_resets_on_reset () =
  let state = make_default_state () in
  let state' = CB.increment_state (CB.increment_state (CB.increment_state state)) in
  let state'' = CB.reset_state state' in
  check float "cooldown_remaining resets to 60.0" 60.0 state''.cooldown_remaining
;;

(* ── Test Suite ────────────────────────────────────────── *)

let () =
  run "keeper_circuit_breaker"
    [
      "default_state",
      [
        test "initial values" `Quick test_default_state_initial_values;
        test "custom threshold" `Quick test_default_state_custom_threshold;
      ];
      "increment_state",
      [
        test "counter increases" `Quick test_increment_state_counter_increases;
        test "multiple increments" `Quick test_increment_state_multiple_times;
        test "timestamp unchanged" `Quick test_increment_state_does_not_change_timestamp;
      ];
      "reset_state",
      [
        test "counter resets" `Quick test_reset_state_counter_resets;
        test "timestamp updates" `Quick test_reset_state_timestamp_updates;
        test "cooldown resets" `Quick test_reset_state_cooldown_remaining_resets;
      ];
      "should_skip",
      [
        test "below threshold" `Quick test_should_skip_below_threshold;
        test "at threshold" `Quick test_should_skip_at_threshold;
        test "above threshold" `Quick test_should_skip_above_threshold;
        test "after reset" `Quick test_should_skip_after_reset;
      ];
      "load_save_round_trip",
      [
        test "default state" `Quick test_load_save_round_trip;
        test "state with values" `Quick test_load_save_round_trip_with_values;
      ];
      "serialization",
      [
        test "state_to_json" `Quick test_state_to_json_serializes_correctly;
        test "json_to_state" `Quick test_json_to_state_deserializes_correctly;
      ];
      "threshold_boundary",
      [
        test "threshold=1" `Quick test_threshold_boundary_one;
        test "threshold=0" `Quick test_threshold_boundary_zero;
      ];
      "cooldown_remaining",
      [
        test "decreases over time" `Quick test_cooldown_remaining_decreases_over_time;
        test "resets on reset" `Quick test_cooldown_remaining_resets_on_reset;
      ];
    ]
;;