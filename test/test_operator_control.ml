let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Masc_mcp.Keeper_exec_tools.init_policy_config ~base_path));
  Alcotest.run "Operator_control"
    [
      ( "operator",
        [
          Alcotest.test_case "snapshot runtime alignment promotes fresh live signal"
            `Quick
            Test_operator_control_snapshot
            .test_align_keeper_runtime_status_promotes_fresh_runtime_signal;
          Alcotest.test_case "snapshot runtime alignment preserves attention health"
            `Quick
            Test_operator_control_snapshot
            .test_align_keeper_runtime_status_preserves_attention_health;
          Alcotest.test_case "snapshot runtime alignment ignores zombie runtime signal"
            `Quick
            Test_operator_control_snapshot
            .test_align_keeper_runtime_status_ignores_zombie_runtime_signal;
          Alcotest.test_case "snapshot sections" `Quick
            Test_operator_control_snapshot.test_snapshot_has_expected_sections;
          Alcotest.test_case "snapshot pending confirm summary tracks actor scope"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_pending_confirm_summary_tracks_actor_scope;
          Alcotest.test_case "snapshot summary view can omit command plane"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_summary_view_can_omit_command_plane;
          Alcotest.test_case "snapshot lightweight summary omits heavy activity"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_lightweight_summary_omits_heavy_activity;
          Alcotest.test_case "snapshot waiters share inflight result" `Quick
            Test_operator_control_snapshot
            .test_snapshot_waiters_share_inflight_result;
          Alcotest.test_case "orchestra room core shape" `Quick
            Test_operator_control_snapshot.test_orchestra_room_core_shape;
          Alcotest.test_case "digest room pending confirm attention" `Quick
            Test_operator_control_snapshot
            .test_digest_room_exposes_pending_confirm_attention;
          Alcotest.test_case "digest room tool host attention" `Quick
            Test_operator_control_snapshot
            .test_digest_room_includes_tool_host_failure_attention;
          Alcotest.test_case "operator digest severity rank supports critical"
            `Quick
            Test_operator_control_snapshot
            .test_operator_digest_severity_rank_supports_critical;
          Alcotest.test_case "digest room prefers fresh operator judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_room_prefers_fresh_operator_judgment;
          Alcotest.test_case "digest room ignores stale operator judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_room_ignores_stale_operator_judgment;
          Alcotest.test_case "operator judgment write and latest roundtrip"
            `Quick
            Test_operator_control_judgment
            .test_operator_judgment_write_and_latest_roundtrip;
          Alcotest.test_case "task inject immediate flow" `Quick
            Test_operator_control_actions
            .test_task_inject_executes_immediately;
          Alcotest.test_case "digest defaults to namespace target" `Quick
            Test_operator_control_actions
            .test_digest_defaults_to_namespace_target;
          Alcotest.test_case "review resolve hides matching item" `Quick
            Test_operator_control_actions
            .test_review_resolve_hides_matching_item;
          Alcotest.test_case "review defer moves item to deferred queue" `Quick
            Test_operator_control_actions
            .test_review_defer_moves_item_to_deferred_queue;
          Alcotest.test_case "confirm keeps token on delegated failure" `Quick
            Test_operator_control_judgment
            .test_confirm_keeps_pending_token_when_delegated_action_fails;
          (* Slow: Eio_linux io_uring crash on GitHub Actions Ubuntu runner.
             Passes locally on macOS (Eio_posix).  See #5449. *)
          Alcotest.test_case "snapshot exposes keeper and social actions" `Slow
            Test_operator_control_keeper.test_snapshot_exposes_keeper_and_social_actions;
          Alcotest.test_case "keeper status exposes summary and recoverable"
            `Quick
            Test_operator_control_keeper
            .test_keeper_status_exposes_summary_and_recoverable;
          Alcotest.test_case "keeper status defaults name to caller" `Quick
            Test_operator_control_keeper
            .test_keeper_status_defaults_name_to_caller;
          Alcotest.test_case "keeper status accepts agent alias" `Quick
            Test_operator_control_keeper
            .test_keeper_status_accepts_agent_name_alias;
          Alcotest.test_case "keeper down accepts agent alias" `Quick
            Test_operator_control_keeper
            .test_keeper_down_accepts_agent_name_alias;
          Alcotest.test_case "keeper list scoped to current base path" `Quick
            Test_operator_control_keeper
            .test_keeper_list_scoped_to_current_base_path;
          Alcotest.test_case "keeper status does not cross base path" `Quick
            Test_operator_control_keeper
            .test_keeper_status_does_not_cross_base_path;
          Alcotest.test_case "keeper down only pauses current base path"
            `Quick
            Test_operator_control_keeper
            .test_keeper_down_only_pauses_current_base_path;
          Alcotest.test_case "operator keeper probe accepts agent alias"
            `Quick
            Test_operator_control_keeper
            .test_operator_keeper_probe_accepts_agent_name_alias;
          Alcotest.test_case "operator keeper recover accepts agent alias"
            `Quick
            Test_operator_control_keeper
            .test_operator_keeper_recover_accepts_agent_name_alias;
          Alcotest.test_case "keeper status schema makes name optional" `Quick
            Test_operator_control_keeper
            .test_keeper_status_schema_makes_name_optional;
          Alcotest.test_case "keeper config exposes live runtime and sources"
            `Quick
            Test_operator_control_keeper
            .test_keeper_config_exposes_live_runtime_and_sources;
          Alcotest.test_case "snapshot keeper tool audit fallback" `Quick
            Test_operator_control_keeper.test_snapshot_keeper_tool_audit_fallback;
          Alcotest.test_case "snapshot keeper tool audit uses decision log"
            `Quick
            Test_operator_control_keeper
            .test_snapshot_keeper_tool_audit_uses_decision_log;
          Alcotest.test_case "keeper msg auto team session bridge" `Quick
            Test_operator_control_keeper.test_keeper_msg_auto_execution_session_bridge;
          Alcotest.test_case "operator keeper_message rejects legacy models"
            `Quick
            Test_operator_control_keeper
            .test_operator_keeper_message_rejects_legacy_model_args;
          Alcotest.test_case "expired confirmation rejected" `Quick
            Test_operator_control_swarm.test_confirm_rejects_expired_token;
          Alcotest.test_case "swarm run continue removed from operator actions" `Quick
            Test_operator_control_swarm
            .test_swarm_run_continue_removed_from_operator_actions;
          Alcotest.test_case "swarm run rerun removed from operator actions" `Quick
            Test_operator_control_swarm
            .test_swarm_run_rerun_removed_from_operator_actions;
          Alcotest.test_case "swarm run abandon removed from operator actions" `Quick
            Test_operator_control_swarm
            .test_swarm_run_abandon_removed_from_operator_actions;
        ] );
    ]
