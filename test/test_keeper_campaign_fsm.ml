open Alcotest

module Fsm = Masc_mcp.Keeper_campaign_fsm
module Json = Yojson.Safe.Util

let phase_t = testable (Fmt.of_to_string Fsm.phase_to_string) ( = )

let apply_ok snapshot event =
  match Fsm.apply_event snapshot event with
  | Ok snapshot -> snapshot
  | Error msg -> fail msg

let apply_err snapshot event =
  match Fsm.apply_event snapshot event with
  | Ok snapshot ->
    failf "expected transition failure, got %s"
      (Fsm.phase_to_string snapshot.phase)
  | Error msg -> msg

let reached_events =
  [
    Fsm.Bootstrap_ok { goal = "reach target" };
    Fsm.Task_bound_observed
      { task_id = "task-001"; current_task_id = "task-001" };
    Fsm.Autoresearch_started
      { loop_id = "ar-001"; target_score = Some 1.0 };
    Fsm.Target_reached_event;
    Fsm.Pressure_started;
    Fsm.Compaction_observed { count = 1 };
    Fsm.Continuity_observed
      { goal_matches = true; current_task_id = Some "task-001" };
  ]

let test_replay_reached () =
  match Fsm.replay reached_events with
  | Error msg -> fail msg
  | Ok snapshot ->
    check phase_t "terminal reached" Fsm.Continuity_verified snapshot.phase;
    check (option string) "verdict" (Some "reached")
      (Fsm.verdict_of_phase snapshot.phase);
    check bool "target_reached" true snapshot.target_reached;
    check int "compaction count" 1 snapshot.compaction_count

let test_replay_stalled () =
  let events =
    [
      Fsm.Bootstrap_ok { goal = "reach target" };
      Fsm.Task_bound_observed
        { task_id = "task-001"; current_task_id = "task-001" };
      Fsm.Autoresearch_started
        { loop_id = "ar-001"; target_score = Some 1.0 };
      Fsm.Window_exhausted { reason = "autoresearch timeout" };
    ]
  in
  match Fsm.replay events with
  | Error msg -> fail msg
  | Ok snapshot ->
    check phase_t "terminal stalled" Fsm.Stalled snapshot.phase;
    check (option string) "verdict" (Some "stalled")
      (Fsm.verdict_of_phase snapshot.phase);
    check (option string) "reason" (Some "autoresearch timeout") snapshot.reason

let test_replay_escalated_on_continuity_loss () =
  let events =
    [
      Fsm.Bootstrap_ok { goal = "reach target" };
      Fsm.Task_bound_observed
        { task_id = "task-001"; current_task_id = "task-001" };
      Fsm.Autoresearch_started
        { loop_id = "ar-001"; target_score = Some 1.0 };
      Fsm.Target_reached_event;
      Fsm.Pressure_started;
      Fsm.Handoff_observed { count = 1; generation = Some 2; trace_id = Some "trace-2" };
      Fsm.Continuity_observed
        { goal_matches = false; current_task_id = Some "task-002" };
    ]
  in
  match Fsm.replay events with
  | Error msg -> fail msg
  | Ok snapshot ->
    check phase_t "terminal escalated" Fsm.Escalated snapshot.phase;
    check (option string) "verdict" (Some "escalated")
      (Fsm.verdict_of_phase snapshot.phase);
    check bool "goal mismatch stored" true
      (snapshot.continuity_goal_matches = Some false);
    check bool "task mismatch stored" true
      (snapshot.continuity_task_matches = Some false)

let test_invalid_pressure_before_target () =
  let snapshot =
    apply_ok Fsm.initial (Fsm.Bootstrap_ok { goal = "reach target" })
    |> fun snapshot ->
    apply_ok snapshot
      (Fsm.Task_bound_observed
         { task_id = "task-001"; current_task_id = "task-001" })
    |> fun snapshot ->
    apply_ok snapshot
      (Fsm.Autoresearch_started
         { loop_id = "ar-001"; target_score = Some 1.0 })
  in
  let err = apply_err snapshot Fsm.Pressure_started in
  check bool "pressure rejected before target"
    true (String.length err > 0)

let test_event_json_roundtrip () =
  let event =
    Fsm.Handoff_observed
      { count = 2; generation = Some 3; trace_id = Some "trace-3" }
  in
  match Fsm.event_of_yojson_result (Fsm.event_to_yojson event) with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "event name"
      (Fsm.event_to_string event) (Fsm.event_to_string decoded)

let test_terminal_phase_is_absorbing () =
  let snapshot =
    match Fsm.replay reached_events with
    | Ok snapshot -> snapshot
    | Error msg -> fail msg
  in
  let err =
    apply_err snapshot
      (Fsm.Error_observed { reason = "should not be accepted" })
  in
  check bool "terminal rejected"
    true (String.length err > 0)

let test_snapshot_json_exposes_terminal_verdict () =
  let terminal =
    match Fsm.replay reached_events with
    | Ok snapshot -> snapshot
    | Error msg -> fail msg
  in
  let searching =
    apply_ok Fsm.initial (Fsm.Bootstrap_ok { goal = "reach target" })
    |> fun snapshot ->
    apply_ok snapshot
      (Fsm.Task_bound_observed
         { task_id = "task-001"; current_task_id = "task-001" })
    |> fun snapshot ->
    apply_ok snapshot
      (Fsm.Autoresearch_started
         { loop_id = "ar-001"; target_score = Some 1.0 })
  in
  let terminal_json = Fsm.snapshot_to_yojson terminal in
  let searching_json = Fsm.snapshot_to_yojson searching in
  check (option string) "terminal verdict present" (Some "reached")
    (Json.member "verdict" terminal_json |> Json.to_string_option);
  check (option string) "non-terminal verdict omitted" None
    (Json.member "verdict" searching_json |> Json.to_string_option)

let () =
  run "keeper_campaign_fsm"
    [
      ( "campaign",
        [
          test_case "replay reached path" `Quick test_replay_reached;
          test_case "replay stalled path" `Quick test_replay_stalled;
          test_case "replay escalated on continuity loss" `Quick
            test_replay_escalated_on_continuity_loss;
          test_case "invalid pressure before target" `Quick
            test_invalid_pressure_before_target;
          test_case "event json roundtrip" `Quick test_event_json_roundtrip;
          test_case "terminal phase is absorbing" `Quick
            test_terminal_phase_is_absorbing;
          test_case "snapshot json exposes terminal verdict" `Quick
            test_snapshot_json_exposes_terminal_verdict;
        ] );
    ]
