let () =
  Alcotest.run "Command_plane_v2"
    [
      ( "scheduler",
        [
          Alcotest.test_case "operation defaults to coding_task best_first" `Quick
            Test_command_plane_v2_scheduler_core_a.test_operation_defaults_to_coding_task_best_first;
          Alcotest.test_case
            "generic alias normalizes to coding_task and keeps artifact scope"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_generic_alias_normalizes_to_coding_task_and_keeps_artifact_scope;
          Alcotest.test_case
            "workload template defaults apply expected profile and stage"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_workload_template_defaults_apply_expected_profile_and_stage;
          Alcotest.test_case
            "workload template rejects mismatched workload profile"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_workload_template_rejects_mismatched_workload_profile;
          Alcotest.test_case
            "coding verify and review require expected dependencies"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_coding_verify_and_review_require_expected_dependencies;
          Alcotest.test_case
            "intent create update and operation inheritance"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_intent_create_update_and_operation_inheritance;
          Alcotest.test_case
            "intent forecast advances after completed operation"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_intent_forecast_advances_after_completed_operation;
          Alcotest.test_case
            "intent state aggregates across parallel operations"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_intent_state_aggregates_across_parallel_operations;
          Alcotest.test_case
            "intent forecast resolves dependencies against all operations"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_intent_forecast_resolves_dependencies_against_all_operations;
          Alcotest.test_case
            "intent forecast blocks on active cross-intent dependency"
            `Quick
            Test_command_plane_v2_scheduler_core_b.test_intent_forecast_blocks_on_active_cross_intent_dependency;
          Alcotest.test_case
            "intent forecast accepts checkpointed cross-intent dependency"
            `Quick
            Test_command_plane_v2_scheduler_core_b.test_intent_forecast_accepts_checkpointed_cross_intent_dependency;
          Alcotest.test_case
            "checkpoint preserves terminal intent state"
            `Quick
            Test_command_plane_v2_scheduler_core_b.test_checkpoint_preserves_terminal_intent_state;
          Alcotest.test_case "platoon assignment expands detachments" `Quick
            Test_command_plane_v2_scheduler_policy.test_platoon_assignment_expands_detachments_and_tick_runs;
          Alcotest.test_case "freeze requires company approval" `Quick
            Test_command_plane_v2_scheduler_policy.test_freeze_requires_company_approval;
          Alcotest.test_case "snapshot json reports consistent sections" `Quick
            Test_command_plane_v2_swarm_history.test_snapshot_json_reports_consistent_sections;
          Alcotest.test_case "best first search blocks and routes research pipeline"
            `Quick
            Test_command_plane_v2_search.test_best_first_search_blocks_and_routes_research_pipeline;
          Alcotest.test_case "invalid search strategy is rejected" `Quick
            Test_command_plane_v2_search.test_invalid_search_strategy_is_rejected;
        ] );
      ( "swarm",
        [
          Alcotest.test_case "swarm live restores completed workers" `Quick
            Test_command_plane_v2_swarm_history.test_swarm_live_json_restores_completed_workers_after_leave;
          Alcotest.test_case "swarm live ignores stale previous-run evidence" `Quick
            Test_command_plane_v2_swarm_history.test_swarm_live_json_ignores_stale_evidence_from_previous_run;
          Alcotest.test_case "swarm live scopes markers to sender" `Quick
            Test_command_plane_v2_swarm_history.test_swarm_live_json_scopes_markers_to_sender;
          Alcotest.test_case "summary json omits heavy arrays" `Quick
            Test_command_plane_v2_swarm_summary.test_summary_json_omits_heavy_arrays_and_keeps_summaries;
          Alcotest.test_case "summary swarm proof prefers artifact" `Quick
            Test_command_plane_v2_swarm_summary.test_summary_json_swarm_proof_prefers_artifact;
          Alcotest.test_case "summary swarm proof fallback and missing" `Quick
            Test_command_plane_v2_swarm_summary.test_summary_json_swarm_proof_fallback_and_missing;
          Alcotest.test_case "swarm live reads custom worker count from operation note" `Quick
            Test_command_plane_v2_swarm_summary.test_swarm_live_json_reads_custom_worker_count_from_operation_note;
          Alcotest.test_case "swarm live reads runtime doctor and blockers" `Quick
            Test_command_plane_v2_swarm_summary.test_swarm_live_json_reads_runtime_doctor_and_blockers;
          Alcotest.test_case "swarm live recommends rerun without resumable state" `Quick
            Test_command_plane_v2_swarm_summary.test_swarm_live_json_recommends_rerun_without_resumable_state;
          Alcotest.test_case "swarm live recommends continue and hides after abandon" `Quick
            Test_command_plane_v2_swarm_summary.test_swarm_live_json_recommends_continue_for_paused_run_and_hides_after_abandon;
          Alcotest.test_case "swarm live wrapper persists summary" `Quick
            Test_command_plane_v2_wrapper.test_swarm_live_run_with_runner_persists_summary;
          Alcotest.test_case "swarm live wrapper reports runner exceptions" `Quick
            Test_command_plane_v2_wrapper.test_swarm_live_run_with_runner_returns_error_on_exception;
          Alcotest.test_case "swarm live wrapper rejects invalid run_id" `Quick
            Test_command_plane_v2_wrapper.test_swarm_live_run_rejects_invalid_run_id;
          Alcotest.test_case "swarm live reports sync self unsupported" `Quick
            Test_command_plane_v2_wrapper.test_swarm_live_run_reports_sync_self_unsupported_after_preflight;
        ] );
    ]
