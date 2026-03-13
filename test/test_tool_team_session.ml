let () =
  Alcotest.run "Tool_team_session"
    [
      ( "team_session",
        [
          Alcotest.test_case "start-status-report-stop" `Quick
            Test_tool_team_session_lifecycle.test_start_status_report_stop;
          Alcotest.test_case "start-attached-operation-session" `Quick
            Test_tool_team_session_lifecycle.test_start_attached_operation_session;
          Alcotest.test_case "proof-exposes-spawn-selection-rationale" `Quick
            Test_tool_team_session_proof.test_proof_exposes_spawn_selection_rationale;
          Alcotest.test_case "bootstrap-grace-suppresses-min-agents-violation"
            `Quick Test_tool_team_session_proof.test_bootstrap_grace_suppresses_min_agents_violation;
          Alcotest.test_case "min-agents-violation-after-bootstrap-grace"
            `Quick Test_tool_team_session_proof.test_min_agents_violation_after_bootstrap_grace;
          Alcotest.test_case "report-uses-participant-and-turn-metrics" `Quick
            Test_tool_team_session_proof.test_report_uses_participant_and_turn_metrics;
          Alcotest.test_case "duration-reached-path" `Quick
            Test_tool_team_session_lifecycle.test_duration_reached_path;
          Alcotest.test_case "recover-elapsed-session" `Quick
            Test_tool_team_session_lifecycle.test_recover_elapsed_session;
          Alcotest.test_case "recover-orphan-session" `Quick
            Test_tool_team_session_flow.test_recover_orphan_session;
          Alcotest.test_case "read-events-limit" `Quick
            Test_tool_team_session_flow.test_read_events_limit;
          Alcotest.test_case "list-and-compare" `Quick Test_tool_team_session_flow.test_list_and_compare;
          Alcotest.test_case "turn-events-prove" `Quick
            Test_tool_team_session_flow.test_turn_events_and_prove;
          Alcotest.test_case "step-plain-turn-matches-legacy-turn" `Quick
            Test_tool_team_session_flow.test_step_plain_turn_matches_legacy_turn;
          Alcotest.test_case "prove-requires-multi-actor-turn-coverage" `Quick
            Test_tool_team_session_proof.test_prove_requires_multi_actor_turn_coverage;
          Alcotest.test_case "missing-required-args" `Quick
            Test_tool_team_session_step_validation.test_missing_required_args;
          Alcotest.test_case "step-actor-must-match-caller" `Quick
            Test_tool_team_session_step_validation.test_step_actor_must_match_caller;
          Alcotest.test_case "step-spawn-requires-proc-mgr" `Quick
            Test_tool_team_session_step_validation.test_step_spawn_requires_proc_mgr;
          Alcotest.test_case "step-spawn-llama-requires-spawn-model" `Quick
            Test_tool_team_session_step_validation.test_step_spawn_llama_requires_spawn_model;
          Alcotest.test_case "step-spawn-batch-records-planned-workers"
            `Quick Test_tool_team_session_step_routing.test_step_spawn_batch_records_planned_workers;
          Alcotest.test_case "step-spawn-batch-applies-hybrid-routing"
            `Quick Test_tool_team_session_step_routing.test_step_spawn_batch_applies_hybrid_routing;
          Alcotest.test_case "parse-step-spawn-specs-applies-top-level-batch-timeout"
            `Quick Test_tool_team_session_step_routing.test_parse_step_spawn_specs_applies_top_level_batch_timeout;
          Alcotest.test_case "step-spawn-batch-infers-exact-env-model-tiers"
            `Quick Test_tool_team_session_step_routing.test_step_spawn_batch_infers_exact_env_model_tiers;
          Alcotest.test_case
            "step-spawn-batch-preserves-explicit-hierarchical-assignments"
            `Quick Test_tool_team_session_step_followup.test_step_spawn_batch_preserves_explicit_hierarchical_assignments;
          Alcotest.test_case "reconcile-failed-spawn-actor-detaches-without-turn"
            `Quick Test_tool_team_session_step_followup.test_reconcile_failed_spawn_actor_detaches_without_turn;
          Alcotest.test_case "reconcile-failed-spawn-actor-retains-after-turn"
            `Quick Test_tool_team_session_step_followup.test_reconcile_failed_spawn_actor_retains_after_turn;
          Alcotest.test_case "proof-exposes-failed-spawn-and-detach-counts"
            `Quick Test_tool_team_session_step_followup.test_proof_exposes_failed_spawn_and_detach_counts;
          Alcotest.test_case "report-and-proof-expose-empty-note-turn-evidence"
            `Quick Test_tool_team_session_step_followup.test_report_and_proof_expose_empty_note_turn_evidence;
          Alcotest.test_case "prove-strong-requires-additional-evidence" `Quick
            Test_tool_team_session_misc.test_prove_strong_requires_additional_evidence;
          Alcotest.test_case "dispatch-unknown" `Quick Test_tool_team_session_misc.test_dispatch_unknown;
          Alcotest.test_case "unauthorized-session-access" `Quick
            Test_tool_team_session_misc.test_unauthorized_session_access;
          Alcotest.test_case "final-done-delta-snapshot-stable" `Quick
            Test_tool_team_session_misc.test_final_done_delta_snapshot_stable;
          Alcotest.test_case "status-and-stop-linked-autoresearch" `Quick
            Test_tool_team_session_misc.test_status_and_stop_linked_autoresearch;
        ] );
    ]
