(** Tool_permission_map — Shared tool→permission resolution. *)

open Types

let declared_permission_for_tool tool_name =
  (Tool_catalog.metadata tool_name).required_permission

let legacy_permission_entries : (string * permission) list =
  [
    ("masc_init", CanInit);
    ("masc_reset", CanReset);
    ("masc_join", CanJoin);
    ("masc_leave", CanLeave);
    ("masc_status", CanReadState);
    ("masc_who", CanReadState);
    ("masc_tasks", CanReadState);
    ("masc_messages", CanReadState);
    ("masc_agents", CanReadState);
    ("masc_worktree_list", CanReadState);
    ("masc_task_history", CanReadState);
    ("masc_operator_snapshot", CanReadState);
    ("masc_operator_digest", CanReadState);
    ("masc_surface_audit", CanReadState);
    ("masc_keeper_status", CanReadState);
    ("masc_keeper_list", CanReadState);
    ("masc_runtime_verify", CanReadState);
    ("masc_runtime_ollama_probe", CanReadState);
    ("masc_unit_list", CanReadState);
    ("masc_operation_status", CanReadState);
    ("masc_policy_status", CanReadState);
    ("masc_dispatch_plan", CanReadState);
    ("masc_observe_topology", CanReadState);
    ("masc_observe_operations", CanReadState);
    ("masc_observe_swarm", CanReadState);
    ("masc_observe_capacity", CanReadState);
    ("masc_observe_alerts", CanReadState);
    ("masc_observe_traces", CanReadState);
    ("masc_agent_card", CanReadState);
    ("masc_agent_fitness", CanReadState);
    ("masc_agent_relations", CanReadState);
    ("masc_dashboard", CanReadState);
    ("masc_check", CanReadState);
    ("masc_collaboration_graph", CanReadState);
    ("masc_feature_flags", CanReadState);
    ("masc_get_metrics", CanReadState);
    ("masc_meta_cognition_snapshot", CanReadState);
    ("masc_poll_events", CanReadState);
    ("masc_recall_search", CanReadState);
    ("masc_room_strategy_get", CanReadState);
    ("masc_select_agent", CanReadState);
    ("masc_auth_list", CanReadState);
    ("masc_verify_auto", CanReadState);
    ("masc_verify_handoff", CanReadState);
    ("masc_verify_pending", CanReadState);
    ("masc_verify_request", CanReadState);
    ("masc_verify_status", CanReadState);
    ("masc_verify_submit", CanReadState);
    ("masc_heartbeat_list", CanReadState);
    ("masc_heartbeat_result", CanReadState);
    ("masc_plan_get_task", CanReadState);
    ("masc_plan_get", CanReadState);
    ("masc_pause_status", CanReadState);
    ("masc_workflow_guide", CanReadState);
    ("masc_autoresearch_status", CanReadState);
    ("masc_config", CanReadState);
    ("masc_add_task", CanAddTask);
    ("masc_claim_next", CanClaimTask);
    ("masc_done", CanCompleteTask);
    ("masc_update_priority", CanCompleteTask);
    ("masc_transition", CanCompleteTask);
    ("masc_release", CanCompleteTask);
    ("masc_broadcast", CanBroadcast);
    ("masc_listen", CanBroadcast);
    ("masc_heartbeat", CanBroadcast);
    ("masc_webrtc_offer", CanBroadcast);
    ("masc_webrtc_answer", CanBroadcast);
    ("channel_gate", CanBroadcast);
    ("masc_register_capabilities", CanBroadcast);
    ("masc_find_by_capability", CanBroadcast);
    ("masc_agent_update", CanBroadcast);
    ("masc_operator_action", CanBroadcast);
    ("masc_keeper_up", CanBroadcast);
    ("masc_keeper_down", CanBroadcast);
    ("masc_keeper_msg", CanBroadcast);
    ("masc_keeper_msg_result", CanBroadcast);
    ("masc_keeper_repair", CanBroadcast);
    ("masc_keeper_reset", CanBroadcast);
    ("masc_keeper_create_from_persona", CanBroadcast);
    ("masc_operator_confirm", CanBroadcast);
    ("masc_unit_define", CanBroadcast);
    ("masc_unit_reparent", CanBroadcast);
    ("masc_unit_reassign", CanBroadcast);
    ("masc_operation_start", CanBroadcast);
    ("masc_operation_checkpoint", CanBroadcast);
    ("masc_operation_pause", CanBroadcast);
    ("masc_operation_resume", CanBroadcast);
    ("masc_operation_stop", CanBroadcast);
    ("masc_operation_finalize", CanBroadcast);
    ("masc_dispatch_assign", CanBroadcast);
    ("masc_dispatch_rebalance", CanBroadcast);
    ("masc_dispatch_escalate", CanBroadcast);
    ("masc_dispatch_recall", CanBroadcast);
    ("masc_policy_approve", CanBroadcast);
    ("masc_policy_deny", CanBroadcast);
    ("masc_policy_update", CanBroadcast);
    ("masc_cleanup_zombies", CanBroadcast);
    ("masc_autoresearch_start", CanAdmin);
    ("masc_autoresearch_swarm_start", CanAdmin);
    ("masc_autoresearch_cycle", CanAdmin);
    ("masc_autoresearch_inject", CanAdmin);
    ("masc_autoresearch_stop", CanAdmin);
    ("masc_board_list", CanReadState);
    ("masc_board_get", CanReadState);
    ("masc_board_hearths", CanReadState);
    ("masc_board_search", CanReadState);
    ("masc_board_profile", CanReadState);
    ("masc_board_stats", CanReadState);
    ("masc_board_post", CanBroadcast);
    ("masc_board_comment", CanBroadcast);
    ("masc_board_vote", CanBroadcast);
    ("masc_board_comment_vote", CanBroadcast);
    ("masc_board_delete", CanAdmin);
    ("masc_auth_enable", CanInit);
    ("masc_auth_disable", CanInit);
    ("masc_auth_revoke", CanInit);
    ("masc_auth_create_token", CanAdmin);
    ("masc_auth_status", CanReadState);
    ("masc_auth_refresh", CanReadState);
    ("masc_tool_stats", CanReadState);
    ("masc_tool_help", CanReadState);
    ("masc_keeper_tool_catalog", CanReadState);
    ("masc_tool_list", CanReadState);
    ("masc_tool_grant", CanAdmin);
    ("masc_tool_revoke", CanAdmin);
    ("masc_tool_admin_snapshot", CanReadState);
    ("masc_tool_admin_update", CanAdmin);
    ("masc_portal_open", CanOpenPortal);
    ("masc_portal_close", CanOpenPortal);
    ("masc_portal_send", CanSendPortal);
    ("masc_worktree_create", CanCreateWorktree);
    ("masc_worktree_remove", CanRemoveWorktree);
  ]

let legacy_permission_for_tool tool_name =
  List.assoc_opt tool_name legacy_permission_entries

let known_tool_names =
  let metadata_tools =
    Tool_catalog.all_surfaces
    |> List.concat_map Tool_catalog.tools_for_surface
  in
  let known = metadata_tools @ List.map fst legacy_permission_entries in
  List.sort_uniq String.compare known

let permission_for_tool tool_name =
  match declared_permission_for_tool tool_name with
  | Some _ as permission -> permission
  | None -> legacy_permission_for_tool tool_name
