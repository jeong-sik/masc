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
    "keeper_stay_silent";
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
    "keeper_shell";
    "keeper_bash";
    "keeper_github";
    "keeper_pr_workflow";
    "keeper_voice_speak";
    (* keeper_voice_listen is keeper-only; there is no public masc_voice_listen
       counterpart on MCP surfaces. *)
    "keeper_voice_listen";
    "keeper_voice_agent";
    "keeper_voice_sessions";
    "keeper_voice_session_start";
    "keeper_voice_session_end";
    (* Tool discovery *)
    "keeper_tool_search";
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
  | "keeper_voice_speak"
  | "keeper_voice_agent"
  | "keeper_voice_sessions"
  | "keeper_voice_session_start"
  | "keeper_voice_session_end" -> None
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
    "masc_keeper_msg"; "masc_keeper_msg_result"; "masc_keeper_list"; "masc_keeper_status";
    "masc_keeper_up"; "masc_keeper_repair"; "masc_keeper_down";
    "masc_persona_list";
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
    "masc_tool_admin_update"; "masc_tool_grant"; "masc_tool_revoke";
    "masc_tool_admin_snapshot";
    "masc_config";
    (* Phase 2: surface SSOT *)
    "masc_auth_disable"; "masc_auth_enable"; "masc_auth_list";
    "masc_auth_refresh"; "masc_auth_revoke"; "masc_auth_status";
    "masc_keeper_create_from_persona";
    "masc_pause"; "masc_resume";
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
    (* WebRTC signaling — deprecated as MCP tools but used as HTTP endpoints *)
    "masc_webrtc_offer"; "masc_webrtc_answer";
    (* Hidden callable tools pruned from user-facing surfaces in #5011. *)
    "masc_archive_view";
    "masc_error_add"; "masc_error_resolve";
    "masc_find_by_capability";
    "masc_keeper_tool_catalog";
    "masc_library_add"; "masc_library_list"; "masc_library_promote";
    "masc_library_read"; "masc_library_search";
    "masc_relay_checkpoint"; "masc_relay_now";
    "masc_relay_smart_check"; "masc_relay_status";
    "masc_room_strategy_get"; "masc_room_strategy_set";
  ]

(* ================================================================ *)
(* Role catalogs — curated subsets for agent role assignment.        *)
(* These are NOT surfaces; they define what a role *should* see.    *)
(* Consumers must filter them against the tools actually surfaced   *)
(* before exposing them to agents.                                 *)
(* ================================================================ *)

let coordination_role_tools : string list =
  [
    "masc_status";
    "masc_tasks";
    "masc_add_task";
    "masc_broadcast";
    "masc_join";
    "masc_leave";
    "masc_who";
    "masc_heartbeat";
    "masc_messages";
    "masc_board_list";
    "masc_board_post";
    "masc_board_comment";
    "masc_board_vote";
    "masc_board_get";
    "masc_claim_next";
    "masc_transition";
    "masc_spawn";
  ]

let execution_role_tools : string list =
  [
    "masc_heartbeat";
    "masc_claim_next";
    "masc_transition";
    "masc_broadcast";
    "masc_code_search";
    "masc_code_symbols";
    "masc_code_read";
    "masc_run_init";
    "masc_run_log";
    "masc_run_deliverable";
    "masc_run_get";
    "masc_tool_help";
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

let surfaces_for_tool name =
  List.filter_map (fun (surface, tbl) ->
    if Hashtbl.mem tbl name then Some surface else None
  ) surface_sets

let surface_to_string = function
  | Public_mcp -> "public_mcp"
  | Spawned_agent -> "spawned_agent"
  | Local_worker -> "local_worker"
  | Session_min -> "session_min"
  | Admin -> "admin"
  | Keeper_internal -> "keeper_internal"
  | Keeper_denied -> "keeper_denied"
  | System_internal -> "system_internal"
