let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Masc_mcp.Keeper_exec_tools.init_policy_config ~base_path));
  Alcotest.run "Operator_control"
    [
      ( "operator",
        [
          Alcotest.test_case "snapshot sections" `Quick
            Test_operator_control_snapshot.test_snapshot_has_expected_sections;
          Alcotest.test_case "snapshot pending confirm summary tracks actor scope"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_pending_confirm_summary_tracks_actor_scope;
          Alcotest.test_case "snapshot caps session recent events" `Quick
            Test_operator_control_snapshot.test_snapshot_caps_session_recent_events;
          Alcotest.test_case "snapshot summary view can omit command plane"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_summary_view_can_omit_command_plane;
          Alcotest.test_case "snapshot lightweight summary omits heavy activity"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_lightweight_summary_omits_heavy_activity;
          Alcotest.test_case "digest team session tolerates null nested status"
            `Quick
            Test_operator_control_snapshot
            .test_digest_team_session_tolerates_null_nested_status;
          Alcotest.test_case
            "snapshot lightweight summary caps completed sessions by recency"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_lightweight_summary_caps_completed_sessions_by_recency;
          Alcotest.test_case "snapshot waiters share inflight result" `Quick
            Test_operator_control_snapshot
            .test_snapshot_waiters_share_inflight_result;
          Alcotest.test_case "orchestra room core shape" `Quick
            Test_operator_control_snapshot.test_orchestra_room_core_shape;
          Alcotest.test_case "orchestra session edge and pending signal" `Quick
            Test_operator_control_snapshot
            .test_orchestra_includes_session_edge_and_pending_signal;
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
          Alcotest.test_case "digest team session shape" `Quick
            Test_operator_control_snapshot.test_digest_team_session_shape;
          Alcotest.test_case "digest team session prefers fresh operator judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_team_session_prefers_fresh_operator_judgment;
          Alcotest.test_case
            "parse session judgment ignores null recommended action"
            `Quick
            Test_operator_control_judgment
            .test_parse_session_judgment_ignores_null_recommended_action;
          Alcotest.test_case "digest team session can skip workers" `Quick
            Test_operator_control_snapshot.test_digest_team_session_can_skip_workers;
          Alcotest.test_case "operator judgment write and latest roundtrip"
            `Quick
            Test_operator_control_judgment
            .test_operator_judgment_write_and_latest_roundtrip;
          Alcotest.test_case "snapshot and digest expose role runtime census"
            `Quick
            Test_operator_control_snapshot
            .test_snapshot_and_digest_expose_role_runtime_census;
          Alcotest.test_case "task inject immediate flow" `Quick
            Test_operator_control_actions
            .test_task_inject_executes_immediately;
          Alcotest.test_case "digest defaults to namespace target" `Quick
            Test_operator_control_actions
            .test_digest_defaults_to_namespace_target;
          Alcotest.test_case "team turn fallback actor" `Quick
            Test_operator_control_actions.test_team_turn_falls_back_to_session_actor;
          Alcotest.test_case "team note logs action" `Quick
            Test_operator_control_actions.test_team_note_records_action_log;
          Alcotest.test_case "team broadcast event" `Quick
            Test_operator_control_actions.test_team_broadcast_records_event;
          Alcotest.test_case "team task inject confirm flow" `Quick
            Test_operator_control_actions
            .test_team_task_inject_requires_confirm_then_executes;
          Alcotest.test_case "team worker spawn batch confirm flow" `Quick
            Test_operator_control_actions
            .test_team_worker_spawn_batch_requires_confirm_then_executes;
          Alcotest.test_case "review resolve hides matching item" `Quick
            Test_operator_control_actions
            .test_review_resolve_hides_matching_item;
          Alcotest.test_case "review defer moves item to deferred queue" `Quick
            Test_operator_control_actions
            .test_review_defer_moves_item_to_deferred_queue;
          Alcotest.test_case "confirm keeps token on delegated failure" `Quick
            Test_operator_control_judgment
            .test_confirm_keeps_pending_token_when_delegated_action_fails;
          Alcotest.test_case "digest recommends worker spawn batch" `Quick
            Test_operator_control_judgment
            .test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn;
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
          Alcotest.test_case "operator keeper probe accepts agent alias"
            `Quick
            Test_operator_control_keeper
            .test_operator_keeper_probe_accepts_agent_name_alias;
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
            Test_operator_control_keeper.test_keeper_msg_auto_team_session_bridge;
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
