(** Unit tests for Team_session_report proof criteria pure functions.

    These tests exercise make_standard_criteria, make_strong_criteria,
    find_criterion, all_criteria_pass, and mandatory_ok_for_level
    without requiring a running server. *)

open Masc_mcp

let check_bool msg expected actual =
  Alcotest.(check bool) msg expected actual

(* ------------------------------------------------------------ *)
(* make_standard_criteria tests                                  *)
(* ------------------------------------------------------------ *)

let test_standard_all_pass () =
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:2 ~communication_total:3
      ~goal_recorded:true ~participants_count:2
      ~unique_turn_actors_count:2 ~required_turn_actors:2
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:5 ()
  in
  check_bool "all_criteria_pass (happy path)" true
    (Team_session_report.all_criteria_pass criteria);
  check_bool "session_started_event" true
    (Team_session_report.find_criterion criteria "session_started_event");
  check_bool "checkpoint_recorded" true
    (Team_session_report.find_criterion criteria "checkpoint_recorded");
  check_bool "turn_or_communication_recorded" true
    (Team_session_report.find_criterion criteria "turn_or_communication_recorded");
  check_bool "goal_recorded" true
    (Team_session_report.find_criterion criteria "goal_recorded");
  check_bool "participants_recorded" true
    (Team_session_report.find_criterion criteria "participants_recorded");
  check_bool "multi_actor_turn_coverage" true
    (Team_session_report.find_criterion criteria "multi_actor_turn_coverage");
  check_bool "turn_actor_authorized" true
    (Team_session_report.find_criterion criteria "turn_actor_authorized");
  check_bool "report_artifacts" true
    (Team_session_report.find_criterion criteria "report_artifacts");
  check_bool "outcome_traceable" true
    (Team_session_report.find_criterion criteria "outcome_traceable")

let test_standard_all_fail () =
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:false
      ~checkpoints_count:0 ~turn_events:0 ~communication_total:0
      ~goal_recorded:false ~participants_count:0
      ~unique_turn_actors_count:0 ~required_turn_actors:2
      ~unauthorized_turn_actors:["intruder"]
      ~report_json_exists:false ~report_md_exists:false
      ~done_delta_total:(-1) ()
  in
  check_bool "all_criteria_pass (all fail)" false
    (Team_session_report.all_criteria_pass criteria);
  check_bool "session_started_event fails" false
    (Team_session_report.find_criterion criteria "session_started_event");
  check_bool "checkpoint fails" false
    (Team_session_report.find_criterion criteria "checkpoint_recorded");
  check_bool "turn_or_communication fails" false
    (Team_session_report.find_criterion criteria "turn_or_communication_recorded");
  check_bool "unauthorized actors fail" false
    (Team_session_report.find_criterion criteria "turn_actor_authorized");
  check_bool "outcome_traceable fails (negative delta)" false
    (Team_session_report.find_criterion criteria "outcome_traceable")

(* ------------------------------------------------------------ *)
(* Edge cases: boundary values                                   *)
(* ------------------------------------------------------------ *)

let test_checkpoint_boundary () =
  let c0 =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:0 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "checkpoint=0 fails" false
    (Team_session_report.find_criterion c0 "checkpoint_recorded");
  let c1 =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "checkpoint=1 passes" true
    (Team_session_report.find_criterion c1 "checkpoint_recorded")

let test_turn_or_communication_edge () =
  (* turn=0, communication=0 -> fail *)
  let c_none =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:0 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "turn=0,comm=0 fails" false
    (Team_session_report.find_criterion c_none "turn_or_communication_recorded");
  (* turn=0, communication=1 -> pass (OR logic) *)
  let c_comm =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:0 ~communication_total:1
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "turn=0,comm=1 passes (OR)" true
    (Team_session_report.find_criterion c_comm "turn_or_communication_recorded");
  (* turn=1, communication=0 -> pass (OR logic) *)
  let c_turn =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[] ~report_json_exists:true
      ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "turn=1,comm=0 passes (OR)" true
    (Team_session_report.find_criterion c_turn "turn_or_communication_recorded")

let test_unauthorized_actors () =
  let c_one =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:["x"]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "one unauthorized actor fails" false
    (Team_session_report.find_criterion c_one "turn_actor_authorized")

let test_report_artifacts_partial () =
  let c_json_only =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:false ~done_delta_total:0 ()
  in
  check_bool "json only -> report_artifacts fails" false
    (Team_session_report.find_criterion c_json_only "report_artifacts");
  let c_md_only =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:false ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "md only -> report_artifacts fails" false
    (Team_session_report.find_criterion c_md_only "report_artifacts")

let test_done_delta_boundary () =
  let c_neg =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:(-1) ()
  in
  check_bool "done_delta=-1 fails" false
    (Team_session_report.find_criterion c_neg "outcome_traceable");
  let c_zero =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "done_delta=0 passes" true
    (Team_session_report.find_criterion c_zero "outcome_traceable")

(* ------------------------------------------------------------ *)
(* find_criterion: missing name returns false                    *)
(* ------------------------------------------------------------ *)

let test_find_criterion_missing () =
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "nonexistent criterion returns false" false
    (Team_session_report.find_criterion criteria "nonexistent_criterion_xyz")

(* ------------------------------------------------------------ *)
(* mandatory_ok_for_level                                        *)
(* ------------------------------------------------------------ *)

let test_mandatory_standard_pass () =
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "standard mandatory ok" true
    (Team_session_report.mandatory_ok_for_level
       ~proof_level:Team_session_types.Proof_standard criteria)

let test_mandatory_standard_fail_no_checkpoint () =
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:0 ~turn_events:1 ~communication_total:0
      ~goal_recorded:true ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "standard fails without checkpoint" false
    (Team_session_report.mandatory_ok_for_level
       ~proof_level:Team_session_types.Proof_standard criteria)

let test_mandatory_strong_requires_all () =
  (* Strong level: even a non-mandatory criterion failing should cause failure *)
  let criteria =
    Team_session_report.make_standard_criteria ~event_started:true
      ~checkpoints_count:1 ~turn_events:1 ~communication_total:0
      ~goal_recorded:false (* non-mandatory for standard, but strong requires all *)
      ~participants_count:1
      ~unique_turn_actors_count:1 ~required_turn_actors:1
      ~unauthorized_turn_actors:[]
      ~report_json_exists:true ~report_md_exists:true ~done_delta_total:0 ()
  in
  check_bool "strong fails when goal missing" false
    (Team_session_report.mandatory_ok_for_level
       ~proof_level:Team_session_types.Proof_strong criteria)

(* ------------------------------------------------------------ *)
(* verdict_for_level                                             *)
(* ------------------------------------------------------------ *)

let test_verdict_standard_proved () =
  Alcotest.(check string) "standard proved"
    "proved"
    (Team_session_report.verdict_for_level
       ~proof_level:Team_session_types.Proof_standard ~mandatory_ok:true)

let test_verdict_standard_insufficient () =
  Alcotest.(check string) "standard insufficient"
    "insufficient_evidence"
    (Team_session_report.verdict_for_level
       ~proof_level:Team_session_types.Proof_standard ~mandatory_ok:false)

let test_verdict_strong_proved () =
  Alcotest.(check string) "strong proved"
    "proved_strong"
    (Team_session_report.verdict_for_level
       ~proof_level:Team_session_types.Proof_strong ~mandatory_ok:true)

let test_verdict_strong_insufficient () =
  Alcotest.(check string) "strong insufficient"
    "insufficient_evidence_strong"
    (Team_session_report.verdict_for_level
       ~proof_level:Team_session_types.Proof_strong ~mandatory_ok:false)

(* ------------------------------------------------------------ *)
(* make_strong_criteria                                          *)
(* ------------------------------------------------------------ *)

let test_strong_criteria_all_pass () =
  let criteria =
    Team_session_report.make_strong_criteria ~required_spawn_agents:2
      ~spawn_events:3 ~spawn_success_count:2 ~unique_spawn_agents_count:2
      ~required_turn_actors:2 ~min_turn_events:5 ~turn_events:10
      ~min_communication:3 ~communication_total:5 ~vote_events:2
      ~run_deliverables:1 ~empty_note_turn_count:0
  in
  check_bool "strong all pass" true
    (Team_session_report.all_criteria_pass criteria)

let test_strong_criteria_empty_notes_fail () =
  let criteria =
    Team_session_report.make_strong_criteria ~required_spawn_agents:1
      ~spawn_events:1 ~spawn_success_count:1 ~unique_spawn_agents_count:1
      ~required_turn_actors:1 ~min_turn_events:1 ~turn_events:1
      ~min_communication:1 ~communication_total:1 ~vote_events:1
      ~run_deliverables:1 ~empty_note_turn_count:1
  in
  check_bool "empty_note_turns_absent fails" false
    (Team_session_report.find_criterion criteria "empty_note_turns_absent")

let test_strong_criteria_no_votes () =
  let criteria =
    Team_session_report.make_strong_criteria ~required_spawn_agents:1
      ~spawn_events:1 ~spawn_success_count:1 ~unique_spawn_agents_count:1
      ~required_turn_actors:1 ~min_turn_events:1 ~turn_events:1
      ~min_communication:1 ~communication_total:1 ~vote_events:0
      ~run_deliverables:1 ~empty_note_turn_count:0
  in
  check_bool "vote_evidence fails with 0 votes" false
    (Team_session_report.find_criterion criteria "vote_evidence_present")

(* ------------------------------------------------------------ *)
(* Test runner                                                   *)
(* ------------------------------------------------------------ *)

let () =
  Alcotest.run "proof_criteria"
    [
      ( "standard_criteria",
        [
          Alcotest.test_case "all pass" `Quick test_standard_all_pass;
          Alcotest.test_case "all fail" `Quick test_standard_all_fail;
          Alcotest.test_case "checkpoint boundary" `Quick test_checkpoint_boundary;
          Alcotest.test_case "turn or communication edge" `Quick
            test_turn_or_communication_edge;
          Alcotest.test_case "unauthorized actors" `Quick test_unauthorized_actors;
          Alcotest.test_case "report artifacts partial" `Quick
            test_report_artifacts_partial;
          Alcotest.test_case "done_delta boundary" `Quick test_done_delta_boundary;
          Alcotest.test_case "find missing criterion" `Quick
            test_find_criterion_missing;
        ] );
      ( "mandatory_ok",
        [
          Alcotest.test_case "standard pass" `Quick test_mandatory_standard_pass;
          Alcotest.test_case "standard fail (no checkpoint)" `Quick
            test_mandatory_standard_fail_no_checkpoint;
          Alcotest.test_case "strong requires all" `Quick
            test_mandatory_strong_requires_all;
        ] );
      ( "verdict",
        [
          Alcotest.test_case "standard proved" `Quick test_verdict_standard_proved;
          Alcotest.test_case "standard insufficient" `Quick
            test_verdict_standard_insufficient;
          Alcotest.test_case "strong proved" `Quick test_verdict_strong_proved;
          Alcotest.test_case "strong insufficient" `Quick
            test_verdict_strong_insufficient;
        ] );
      ( "strong_criteria",
        [
          Alcotest.test_case "all pass" `Quick test_strong_criteria_all_pass;
          Alcotest.test_case "empty notes fail" `Quick
            test_strong_criteria_empty_notes_fail;
          Alcotest.test_case "no votes fail" `Quick test_strong_criteria_no_votes;
        ] );
    ]
