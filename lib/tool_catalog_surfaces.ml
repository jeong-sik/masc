(** Tool_catalog_surfaces — Canonical per-surface tool name lists.

    SSOT for tool surface membership. All other modules should derive their
    allowlists from [tools_for_surface] instead of maintaining independent
    hardcoded lists.

    This module is a leaf dependency — it depends only on string lists and
    Env_config. Extracted from tool_catalog.ml to enable SCC cycle-breaking:
    keeper modules can depend on this leaf module instead of the full
    Tool_catalog.

    @since 2.188.0 — God file decomposition Phase 1 *)

(* ================================================================ *)
(* Keeper-internal tools                                            *)
(* ================================================================ *)

let keeper_internal_tools =
  [
    (* keeper_read removed: dead alias for keeper_fs_read with no schema.
       Dispatch still accepts it for backward compat. See #4120. *)
    "keeper_fs_read";
    "keeper_fs_edit";
    "keeper_memory_search";
    "keeper_library_search";
    "keeper_library_read";
    "keeper_time_now";
    "keeper_tools_list";
    "keeper_context_status";
    "keeper_tasks_list";
    "keeper_tasks_audit";
    "keeper_task_claim";
    "keeper_task_done";
    "keeper_task_force_release";
    "keeper_task_force_done";
    "keeper_broadcast";
    "keeper_board_get";
    "keeper_board_post";
    "keeper_board_list";
    "keeper_board_comment";
    "keeper_board_vote";
    "keeper_board_stats";
    "keeper_board_search";
    (* keeper_board_delete removed from default shard in #4309.
       Dispatch still accepts it for backward compat. *)
    "keeper_shell_readonly";
    "keeper_bash";
    "keeper_github";
    (* keeper_deliberation_decision: Agent_sdk.Structured result schema, not
       a regular tool — does not need a keeper shard entry.
       keeper_unified: cascade name, not a tool. *)
  ]

let keeper_internal_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_internal_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_internal_tools;
  tbl

let keeper_internal_replacement = function
  | "keeper_board_get" -> Some "masc_board_get"
  | "keeper_board_post" -> Some "masc_board_post"
  | "keeper_board_list" -> Some "masc_board_list"
  | "keeper_board_comment" -> Some "masc_board_comment"
  | "keeper_board_vote" -> Some "masc_board_vote"
  | "keeper_board_stats" -> Some "masc_board_stats"
  | "keeper_board_search" -> Some "masc_board_search"
  | "keeper_tasks_list" -> Some "masc_tasks"
  | "keeper_broadcast" -> Some "masc_broadcast"
  | _ -> None

(* ================================================================ *)
(* Workspace mutation classification                                *)
(* ================================================================ *)

(** Tools that mutate the workspace filesystem. Canonical list shared by
    cdal_contract_bridge.ml and contract_risk.ml. *)
let workspace_mutating_tool_names =
  [ "keeper_fs_edit"; "keeper_write";
    "create_text_file"; "edit_text_file"; "file_write" ]

(* ================================================================ *)
(* Surface type + canonical lists                                   *)
(* ================================================================ *)

type surface =
  | Public_mcp
  | Spawned_agent
  | Local_worker
  | Session_min
  | Admin
  | Keeper_internal
  | Keeper_denied
  | System_internal

let public_mcp_surface_tools =
  [
    (* Room lifecycle *)
    "masc_start"; "masc_join"; "masc_leave"; "masc_status";
    (* Messaging *)
    "masc_broadcast"; "masc_messages"; "masc_who";
    (* Task coordination *)
    "masc_add_task"; "masc_batch_add_tasks"; "masc_tasks";
    "masc_claim_next"; "masc_transition";
    (* Planning *)
    "masc_plan_init"; "masc_plan_get"; "masc_plan_set_task"; "masc_plan_update";
    (* Heartbeat *)
    "masc_heartbeat";
    (* Keeper interaction *)
    "masc_keeper_msg"; "masc_keeper_list"; "masc_keeper_status";
    "masc_keeper_up"; "masc_keeper_repair"; "masc_keeper_down";
    (* Board *)
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_delete";
    (* Agent discovery *)
    "masc_agents"; "masc_dashboard"; "masc_agent_card";
    (* Utility *)
    "masc_tool_help"; "masc_web_search"; "masc_check";
    (* Board extended *)
    "masc_board_stats"; "masc_board_comment_vote";
    "masc_board_profile"; "masc_board_hearths";
    (* Agent discovery *)
    "masc_agent_timeline";
    (* Phase 2: surface SSOT *)
    "masc_bounded_run";
    "masc_recall_search";
    "masc_verify_auto"; "masc_verify_handoff"; "masc_verify_pending";
    "masc_verify_request"; "masc_verify_status"; "masc_verify_submit";
  ]

let spawned_agent_surface_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_task_history"; "masc_broadcast"; "masc_join"; "masc_leave";
    "masc_who"; "masc_agent_update"; "masc_add_task"; "masc_heartbeat";
    "masc_messages";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
    "masc_handover_create"; "masc_handover_list"; "masc_handover_claim";
    "masc_handover_get";
    "masc_board_list"; "masc_board_post"; "masc_board_comment";
    "masc_board_vote"; "masc_board_get";
    "masc_tool_help"; "masc_web_search";
    "masc_team_session_start"; "masc_team_session_step";
    "masc_team_session_status"; "masc_team_session_events";
    "masc_team_session_finalize"; "masc_team_session_stop";
    "masc_team_session_report"; "masc_team_session_list";
    "masc_poll_events"; "masc_spawn";
    "masc_note_add";
    (* Phase 2: surface SSOT *)
    "masc_code_delete"; "masc_code_edit"; "masc_code_git";
    "masc_code_shell"; "masc_code_write";
    "masc_deliver";
    "masc_plan_clear_task"; "masc_plan_get_task";
    "masc_update_priority";
    "masc_verify_handoff"; "masc_workflow_guide";
  ]

let local_worker_surface_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_add_task"; "masc_heartbeat";
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_search";
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable"; "masc_run_get"; "masc_run_list";
    "masc_repair_loop_start"; "masc_repair_loop_status";
    "masc_repair_loop_iterate"; "masc_repair_loop_stop";
  ]

let session_min_surface_tools =
  [
    "masc_room_status"; "masc_list_tasks"; "masc_claim_next";
    "masc_plan_set_task"; "masc_transition"; "masc_add_task";
    "masc_broadcast"; "masc_heartbeat";
  ]

let admin_surface_tools =
  [
    "masc_auth_create_token";
    "masc_autoresearch_cycle"; "masc_autoresearch_inject";
    "masc_autoresearch_start"; "masc_autoresearch_stop";
    "masc_autoresearch_swarm_start";
    "masc_repo_synthesis_swarm_start";
    "masc_policy_freeze_unit"; "masc_policy_kill_switch";
    "masc_tool_admin_update"; "masc_tool_grant"; "masc_tool_revoke";
    "masc_operator_action"; "masc_operator_confirm"; "masc_operator_snapshot";
    "masc_team_session_finalize"; "masc_tool_admin_snapshot";
    "masc_config";
    (* Phase 2: surface SSOT *)
    "masc_auth_disable"; "masc_auth_enable"; "masc_auth_list";
    "masc_auth_refresh"; "masc_auth_revoke"; "masc_auth_status";
    "masc_dispatch_assign"; "masc_dispatch_escalate"; "masc_dispatch_plan";
    "masc_dispatch_rebalance"; "masc_dispatch_recall"; "masc_dispatch_tick";
    "masc_keeper_create_from_persona";
    "masc_operator_digest";
    "masc_pause"; "masc_resume";
    "masc_policy_approve"; "masc_policy_deny"; "masc_policy_status"; "masc_policy_update";
    "masc_runtime_verify"; "masc_tool_list";
  ]

let keeper_internal_surface_tools = keeper_internal_tools

let keeper_denied_surface_tools =
  [
    "masc_room_delete";
    "masc_force_leave";
    "masc_admin_reset"; "masc_admin_cleanup";
    "masc_gc_force"; "masc_config_set";
    "masc_reset";
    "masc_spawn";
    "masc_operator_action"; "masc_operator_confirm";
    "masc_operator_judgment_write";
    "masc_execute"; "masc_execute_dry_run";
  ]

let system_internal_surface_tools =
  [
    (* MCP protocol internals *)
    "masc_mcp_session"; "masc_suspend"; "masc_listen";
    (* Session lifecycle — auto-called *)
    "masc_init"; "masc_reset"; "masc_register_capabilities";
    (* Namespace onboarding compatibility alias *)
    "masc_set_room";
    (* Governance pipeline — auto-executed *)
    "masc_governance_set";
    (* Concurrency control *)
    "masc_lock"; "masc_unlock";
    (* Heartbeat system loop *)
    "masc_heartbeat_start"; "masc_heartbeat_stop";
    "masc_heartbeat_list"; "masc_heartbeat_result";
    (* Task lifecycle — SDK internal *)
    "masc_cancel_task"; "masc_claim_task"; "masc_complete_task";
    "masc_release_task"; "masc_set_current_task";
    (* Agent evaluation — system loop *)
    "masc_agent_fitness"; "masc_agent_relations";
    "masc_meta_cognition_snapshot"; "masc_consolidate_learning";
    "masc_select_agent";
    (* Maintenance *)
    "masc_cleanup_zombies"; "masc_gc";
    (* Infrastructure control *)
    "masc_cancellation"; "masc_subscription"; "masc_progress";
    "masc_feature_flags"; "masc_compact_context";
    (* Internal monitoring *)
    "masc_autoresearch_status"; "masc_pause_status";
    "masc_tool_stats"; "masc_surface_audit";
    (* Phase 2 addition *)
    "masc_get_metrics";
    (* Portal subsystem — schema-registered, not yet public *)
    "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
    "masc_portal_status";
    (* A2A federation — schema-registered, not yet public *)
    "masc_a2a_discover"; "masc_a2a_query_skill"; "masc_a2a_delegate";
    "masc_a2a_subscribe"; "masc_a2a_unsubscribe";
    (* Transport layer *)
    "masc_transport_status"; "masc_websocket_discovery";
    "masc_webrtc_offer"; "masc_webrtc_answer";
    (* Episode persistence *)
    "masc_episode_flush"; "masc_episode_list";
    (* Board moderation *)
    "masc_board_migrate"; "masc_board_reclassify";
    (* Voice subsystem — schema-registered, not yet public *)
    "masc_voice_ping_pong"; "masc_voice_speak";
    "masc_voice_session_start"; "masc_voice_session_end";
    "masc_voice_sessions"; "masc_voice_agent";
    "masc_voice_conference_start"; "masc_voice_conference_end";
    (* Hidden callable tools pruned from user-facing surfaces in #5011. *)
    "masc_archive_view";
    "masc_collaboration_evidence"; "masc_collaboration_graph";
    "masc_detachment_list"; "masc_detachment_status";
    "masc_error_add"; "masc_error_resolve";
    "masc_find_by_capability";
    "masc_improve_loop_start"; "masc_improve_loop_status";
    "masc_improve_loop_pause"; "masc_improve_loop_resume";
    "masc_improve_loop_tick";
    "masc_keeper_tool_catalog";
    "masc_library_add"; "masc_library_list"; "masc_library_promote";
    "masc_library_read"; "masc_library_search";
    "masc_observe_alerts"; "masc_observe_capacity";
    "masc_observe_operations"; "masc_observe_swarm";
    "masc_observe_topology"; "masc_observe_traces";
    "masc_operation_checkpoint"; "masc_operation_finalize";
    "masc_operation_pause"; "masc_operation_resume";
    "masc_operation_start"; "masc_operation_status"; "masc_operation_stop";
    "masc_relay_checkpoint"; "masc_relay_now";
    "masc_relay_smart_check"; "masc_relay_status";
    "masc_room_strategy_get"; "masc_room_strategy_set";
    "masc_team_session_compare"; "masc_team_session_prove";
    "masc_unit_define"; "masc_unit_list";
    "masc_unit_reassign"; "masc_unit_reparent";
  ]

(* ================================================================ *)
(* Surface query functions                                          *)
(* ================================================================ *)

let tools_for_surface = function
  | Public_mcp -> public_mcp_surface_tools
  | Spawned_agent -> spawned_agent_surface_tools
  | Local_worker -> local_worker_surface_tools
  | Session_min -> session_min_surface_tools
  | Admin -> admin_surface_tools
  | Keeper_internal -> keeper_internal_surface_tools
  | Keeper_denied -> keeper_denied_surface_tools
  | System_internal -> system_internal_surface_tools

let all_surfaces =
  [Public_mcp; Spawned_agent; Local_worker; Session_min;
   Admin; Keeper_internal; Keeper_denied; System_internal]

let surface_sets : (surface * (string, unit) Hashtbl.t) list =
  List.map (fun surface ->
    let tools = tools_for_surface surface in
    let tbl = Hashtbl.create (List.length tools) in
    List.iter (fun name -> Hashtbl.replace tbl name ()) tools;
    (surface, tbl)
  ) all_surfaces

let is_on_surface surface name =
  match List.assoc_opt surface surface_sets with
  | Some tbl -> Hashtbl.mem tbl name
  | None -> false

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent -> "spawned_agent"
  | Local_worker -> "local_worker"
  | Session_min -> "session_min"
  | Admin -> "admin"
  | Keeper_internal -> "keeper_internal"
  | Keeper_denied -> "keeper_denied"
  | System_internal -> "system_internal"
