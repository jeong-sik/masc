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
    "keeper_shell_readonly";
    "keeper_bash";
    "keeper_github";
    "keeper_voice_speak";
    "keeper_voice_agent";
    "keeper_voice_sessions";
    "keeper_voice_session_start";
    "keeper_voice_session_end";
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
  | "keeper_voice_speak" -> Some "masc_voice_speak"
  | "keeper_voice_agent" -> Some "masc_voice_agent"
  | "keeper_voice_sessions" -> Some "masc_voice_sessions"
  | "keeper_voice_session_start" -> Some "masc_voice_session_start"
  | "keeper_voice_session_end" -> Some "masc_voice_session_end"
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
  | Mdal_auditable

let public_mcp_surface_tools =
  [
    (* Room lifecycle *)
    "masc_start"; "masc_join"; "masc_leave"; "masc_set_room"; "masc_status";
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
    (* Transport *)
    "masc_transport_status"; "masc_websocket_discovery";
    "masc_webrtc_offer"; "masc_webrtc_answer";
    (* Utility *)
    "masc_tool_help"; "masc_check";
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
    "masc_relay_status"; "masc_relay_checkpoint";
    "masc_board_list"; "masc_board_post"; "masc_board_comment";
    "masc_board_vote"; "masc_board_get";
    "masc_tool_help";
    "masc_portal_open"; "masc_portal_send"; "masc_portal_status";
    "masc_team_session_start"; "masc_team_session_step";
    "masc_team_session_status"; "masc_team_session_events";
    "masc_team_session_finalize"; "masc_team_session_stop";
    "masc_team_session_report"; "masc_team_session_list";
    "masc_a2a_delegate"; "masc_a2a_subscribe";
    "masc_poll_events"; "masc_spawn";
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
  ]

let keeper_internal_surface_tools = keeper_internal_tools

let keeper_denied_surface_tools =
  [
    "masc_room_delete"; "masc_room_destroy";
    "masc_force_leave"; "masc_force_remove_agent";
    "masc_admin_reset"; "masc_admin_cleanup";
    "masc_gc_force"; "masc_config_set"; "masc_config_reset";
    "masc_spawn";
    "masc_operator_action"; "masc_operator_confirm";
    "masc_operator_judgment_write";
    "masc_execute"; "masc_execute_dry_run";
    "masc_neo4j_query"; "masc_pg_query";
  ]

let mdal_auditable_surface_tools =
  [
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_worktree_create"; "masc_worktree_list"; "masc_worktree_remove";
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable"; "masc_run_get"; "masc_run_list";
    "masc_spawn";
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
  | Mdal_auditable -> mdal_auditable_surface_tools

let all_surfaces =
  [Public_mcp; Spawned_agent; Local_worker; Session_min;
   Admin; Keeper_internal; Keeper_denied; Mdal_auditable]

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
  | Mdal_auditable -> "mdal_auditable"
