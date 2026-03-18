let () =
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
          Alcotest.test_case "orchestra room core shape" `Quick
            Test_operator_control_snapshot.test_orchestra_room_core_shape;
          Alcotest.test_case "orchestra session edge and pending signal" `Quick
            Test_operator_control_snapshot
            .test_orchestra_includes_session_edge_and_pending_signal;
          Alcotest.test_case "digest room pending confirm attention" `Quick
            Test_operator_control_snapshot
            .test_digest_room_exposes_pending_confirm_attention;
          Alcotest.test_case "digest room prefers fresh resident judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_room_prefers_fresh_resident_judgment;
          Alcotest.test_case "digest room ignores stale resident judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_room_ignores_stale_resident_judgment;
          Alcotest.test_case "digest team session shape" `Quick
            Test_operator_control_snapshot.test_digest_team_session_shape;
          Alcotest.test_case "digest team session prefers fresh resident judgment"
            `Quick
            Test_operator_control_judgment
            .test_digest_team_session_prefers_fresh_resident_judgment;
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
          Alcotest.test_case "task inject confirm flow" `Quick
            Test_operator_control_actions
            .test_task_inject_requires_confirm_then_executes;
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
          Alcotest.test_case "confirm keeps token on delegated failure" `Quick
            Test_operator_control_judgment
            .test_confirm_keeps_pending_token_when_delegated_action_fails;
          Alcotest.test_case "digest recommends worker spawn batch" `Quick
            Test_operator_control_judgment
            .test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn;
          Alcotest.test_case "snapshot exposes keeper and social actions" `Quick
            Test_operator_control_keeper.test_snapshot_exposes_keeper_and_social_actions;
          (* Lodge heartbeat test removed — deprecated #1596 *)
          Alcotest.test_case "keeper status exposes summary and recoverable"
            `Quick
            Test_operator_control_keeper
            .test_keeper_status_exposes_summary_and_recoverable;
          Alcotest.test_case "snapshot keeper tool audit fallback" `Quick
            Test_operator_control_keeper.test_snapshot_keeper_tool_audit_fallback;
          Alcotest.test_case "keeper msg auto team session bridge" `Quick
            Test_operator_control_keeper.test_keeper_msg_auto_team_session_bridge;
          (* Lodge tick test removed — deprecated #1596 *)
          Alcotest.test_case "expired confirmation rejected" `Quick
            Test_operator_control_swarm.test_confirm_rejects_expired_token;
          Alcotest.test_case "swarm run continue confirm flow" `Quick
            Test_operator_control_swarm
            .test_swarm_run_continue_requires_confirm_then_executes;
          Alcotest.test_case "swarm run abandon soft resolution" `Quick
            Test_operator_control_swarm
            .test_swarm_run_abandon_records_soft_resolution;
        ] );
    ]
