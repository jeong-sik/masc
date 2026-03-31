let () =
  Alcotest.run ~verbose:true "Tool_team_session"
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
          Alcotest.test_case "report-and-proof-expose-spawn-tool-usage" `Quick
            Test_tool_team_session_proof.test_report_and_proof_expose_spawn_tool_usage;
          Alcotest.test_case "report-and-proof-expose-delivery-contract-and-verdict"
            `Quick
            Test_tool_team_session_proof
              .test_report_and_proof_expose_delivery_contract_and_verdict;
          Alcotest.test_case "proof-aggregates-worker-proof-refs" `Quick
            Test_tool_team_session_proof.test_proof_aggregates_worker_proof_refs;
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
          Alcotest.test_case "idle-session-stays-running-before-first-step"
            `Quick
            Test_tool_team_session_flow
              .test_idle_session_stays_running_before_first_step;
          Alcotest.test_case "prove-requires-multi-actor-turn-coverage" `Quick
            Test_tool_team_session_proof.test_prove_requires_multi_actor_turn_coverage;
          Alcotest.test_case "missing-required-args" `Quick
            Test_tool_team_session_step_validation.test_missing_required_args;
          Alcotest.test_case "step-actor-must-match-caller" `Quick
            Test_tool_team_session_step_validation.test_step_actor_must_match_caller;
          Alcotest.test_case "step-updates-delivery-contract-and-status-exposes-it"
            `Quick
            Test_tool_team_session_step_validation
              .test_step_updates_delivery_contract_and_status_exposes_it;
          Alcotest.test_case "step-spawn-requires-proc-mgr" `Quick
            Test_tool_team_session_step_validation.test_step_spawn_requires_proc_mgr;
          Alcotest.test_case "step-spawn-default-local-allows-worker-size" `Quick
            Test_tool_team_session_step_validation.test_step_spawn_default_local_allows_worker_size_without_spawn_model;
          Alcotest.test_case "step-spawn-batch-defaults-execution-scope" `Quick
            Test_tool_team_session_step_validation.test_step_spawn_batch_defaults_execution_scope_by_worker_class;
          Alcotest.test_case "step-rejects-legacy-spawn-fields" `Quick
            Test_tool_team_session_step_validation.test_step_rejects_legacy_spawn_fields;
          Alcotest.test_case "step-rejects-legacy-batch-spawn-fields" `Quick
            Test_tool_team_session_step_validation.test_step_rejects_legacy_batch_spawn_fields;
          Alcotest.test_case "step-delegate-requires-target-agent" `Quick
            Test_tool_team_session_step_validation.test_step_delegate_requires_target_agent;
          Alcotest.test_case "step-delegate-unknown-worker-rejected" `Quick
            Test_tool_team_session_step_validation.test_step_delegate_unknown_worker_rejected;
          Alcotest.test_case "step-spawn-batch-records-planned-workers"
            `Quick Test_tool_team_session_step_routing.test_step_spawn_batch_records_planned_workers;
          Alcotest.test_case "step-spawn-batch-applies-hybrid-routing"
            `Quick Test_tool_team_session_step_routing.test_step_spawn_batch_applies_hybrid_routing;
          Alcotest.test_case "parse-step-spawn-specs-applies-top-level-batch-timeout"
            `Quick Test_tool_team_session_step_routing.test_parse_step_spawn_specs_applies_top_level_batch_timeout;
          Alcotest.test_case "parse-step-spawn-specs-applies-worker-policy-fields"
            `Quick Test_tool_team_session_step_routing.test_parse_step_spawn_specs_applies_worker_policy_fields;
          Alcotest.test_case "status-reports-worker-run-progress-summary" `Quick
            Test_tool_team_session_step_routing.test_status_reports_worker_run_progress_summary;
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
          Alcotest.test_case "start-requires-process-mgr-when-runtime-unavailable"
            `Quick
            Test_tool_team_session_misc
              .test_start_requires_process_mgr_when_runtime_unavailable;
          Alcotest.test_case "unauthorized-session-access" `Quick
            Test_tool_team_session_misc.test_unauthorized_session_access;
          Alcotest.test_case "final-done-delta-snapshot-stable" `Quick
            Test_tool_team_session_misc.test_final_done_delta_snapshot_stable;
          Alcotest.test_case "verify-trace-uses-worker-run-raw-trace"
            `Quick
            Test_tool_team_session_misc.test_verify_trace_uses_worker_run_raw_trace;
          Alcotest.test_case
            "verify-trace-reports-summary-only-when-direct-evidence-missing"
            `Quick
            Test_tool_team_session_misc
              .test_verify_trace_reports_summary_only_when_direct_evidence_missing;
          Alcotest.test_case
            "delegate-rejects-not-ready-worker-with-guidance" `Quick
            Test_tool_team_session_misc
              .test_delegate_rejects_not_ready_worker_with_guidance;
          Alcotest.test_case
            "verify-trace-reports-summary-only-without-checkpoint" `Quick
            Test_tool_team_session_misc.test_verify_trace_reports_summary_only_without_checkpoint;
          Alcotest.test_case "memory-backend-event-lock-serializes-fibers"
            `Quick
            Test_tool_team_session_flow
              .test_memory_backend_event_lock_serializes_fibers;
          Alcotest.test_case "filesystem-backend-event-lock-serializes-fibers"
            `Quick
            Test_tool_team_session_flow
              .test_filesystem_backend_event_lock_serializes_fibers;
        ] );
    ]
