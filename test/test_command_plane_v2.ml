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
            "start operation uses legacy chain run_id as checkpoint_ref"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_start_operation_uses_legacy_chain_run_id_as_checkpoint_ref;
          Alcotest.test_case
            "operation json preserves chain null for wire compat"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_operation_json_preserves_chain_null_for_wire_compat;
          Alcotest.test_case
            "operation of json uses legacy chain run_id as checkpoint_ref"
            `Quick
            Test_command_plane_v2_scheduler_core_a.test_operation_of_json_uses_legacy_chain_run_id_as_checkpoint_ref;
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
          Alcotest.test_case "best first search blocks and routes research pipeline"
            `Quick
            Test_command_plane_v2_search.test_best_first_search_blocks_and_routes_research_pipeline;
          Alcotest.test_case
            "best first search skips units blocked by tool allowlist"
            `Quick
            Test_command_plane_v2_search.test_best_first_search_skips_units_blocked_by_tool_allowlist;
          Alcotest.test_case "invalid search strategy is rejected" `Quick
            Test_command_plane_v2_search.test_invalid_search_strategy_is_rejected;
          Alcotest.test_case
            "operation trace filter keeps older matching cp events"
            `Quick
            Test_command_plane_v2_traces.test_operation_filter_reads_tail_bounded_event_log;
          Alcotest.test_case
            "trace filter keeps older matching operator events"
            `Quick
            Test_command_plane_v2_traces.test_trace_filter_reads_tail_bounded_operator_log;
          Alcotest.test_case
            "default trace view reuses cached operator events"
            `Quick
            Test_command_plane_v2_traces
              .test_default_trace_view_reuses_cached_operator_events_when_inputs_unchanged;
          Alcotest.test_case
            "default trace view invalidates cache on event log change"
            `Quick
            Test_command_plane_v2_traces
              .test_default_trace_view_invalidates_cache_when_event_log_changes;
          Alcotest.test_case
            "swarm proof fallback reads bounded slot-sample tail"
            `Quick
            Test_command_plane_v2_summary
              .test_swarm_proof_fallback_reads_slot_samples_from_bounded_tail;
          Alcotest.test_case "dispatch assign requires operation_id" `Quick
            Test_command_plane_v2_policy_inputs.test_dispatch_assign_requires_operation_id;
          Alcotest.test_case "dispatch escalate requires operation_id"
            `Quick
            Test_command_plane_v2_policy_inputs.test_dispatch_escalate_requires_operation_id;
          Alcotest.test_case "unit reparent requires unit_id" `Quick
            Test_command_plane_v2_policy_inputs.test_unit_reparent_requires_unit_id;
          Alcotest.test_case "policy update requires unit_id" `Quick
            Test_command_plane_v2_policy_inputs.test_policy_update_requires_unit_id;
          Alcotest.test_case
            "start operation rejects unit policy model mismatch"
            `Quick
            Test_command_plane_v2_policy_inputs.test_start_operation_rejects_unit_policy_model_mismatch;
        ] );
    ]
