(** Negative / edge-case tests for Keeper_transition_audit.
    These cover the paths that PR #9686 added but didn't test. *)

open Alcotest

module Audit = Masc_mcp.Keeper_transition_audit
module KSM = Masc_mcp.Keeper_state_machine

let fail = Alcotest.fail

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_transition_audit_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_env key value f =
  let old_value = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old_value with
      | Some old -> Unix.putenv key old
      | None -> Unix.putenv key "")
    f

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String (name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "transition-audit-test");
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let transition ?(prev_phase = KSM.Running) ?(new_phase = KSM.Paused)
    ?(selected_event = KSM.Operator_pause) () : Audit.transition_record =
  {
    Audit.snapshot = None;
    events_fired = [ selected_event ];
    selected_event;
    prev_phase;
    new_phase;
    transition_outcome = "applied";
    wall_clock_at_decision = 1_712_000_000.5;
  }

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

let test_operator_pause_signal_requires_decision () =
  let json = Audit.to_json (transition ()) in
  let open Yojson.Safe.Util in
  check string "event type" "operator_pause"
    (json |> member "event_type" |> to_string);
  let signal = json |> member "operator_signal" in
  check string "class" "operator_gate" (signal |> member "class" |> to_string);
  check string "severity" "warn" (signal |> member "severity" |> to_string);
  check bool "requires decision" true
    (signal |> member "requires_operator_decision" |> to_bool);
  check string "next action" "resume_or_update_policy"
    (signal |> member "next_human_action" |> to_string)

let test_compact_retry_exhausted_signal_is_alerting () =
  let json =
    Audit.to_json
      (transition ~new_phase:KSM.Paused
         ~selected_event:KSM.Compact_retry_exhausted ())
  in
  let open Yojson.Safe.Util in
  let signal = json |> member "operator_signal" in
  check string "event type" "compact_retry_exhausted"
    (json |> member "event_type" |> to_string);
  check string "class" "context_management"
    (signal |> member "class" |> to_string);
  check string "severity" "bad" (signal |> member "severity" |> to_string);
  check bool "requires decision" true
    (signal |> member "requires_operator_decision" |> to_bool);
  check string "next action" "approve_handoff_or_reduce_context"
    (signal |> member "next_human_action" |> to_string)

let test_runtime_trust_timeline_carries_transition_operator_signal () =
  Audit.For_testing.reset_state ();
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_state ();
      cleanup_dir base_dir)
    (fun () ->
      let sink = Filename.concat base_dir "transition-audit.jsonl" in
      with_env "MASC_KEEPER_TRANSITION_LOG" sink (fun () ->
          let keeper_name = "runtime-trust-transition-signal" in
          let config = Masc_mcp.Coord.default_config base_dir in
          let meta = keeper_meta keeper_name in
          Audit.record_transition ~keeper_name (transition ());
          let snapshot =
            Masc_mcp.Keeper_runtime_trust_snapshot.snapshot_json ~config ~meta
          in
          let open Yojson.Safe.Util in
          let event = snapshot |> member "latest_causal_event" in
          check string "latest event kind" "transition"
            (event |> member "kind" |> to_string);
          check string "transition next action" "resume_or_update_policy"
            (event |> member "next_human_action" |> to_string);
          check string "transition severity" "warn"
            (event |> member "severity" |> to_string)))

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
      ( "transition_operator_signal",
        [
          test_case "operator pause requires decision" `Quick
            test_operator_pause_signal_requires_decision;
          test_case "compact retry exhausted is alerting" `Quick
            test_compact_retry_exhausted_signal_is_alerting;
          test_case "runtime trust timeline carries signal" `Quick
            test_runtime_trust_timeline_carries_transition_operator_signal;
        ] );
    ]
