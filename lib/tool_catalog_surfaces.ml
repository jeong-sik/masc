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
    "keeper_voice_speak";
    (* keeper_voice_listen is keeper-only; there is no public masc_voice_listen
       counterpart on MCP surfaces. *)
    "keeper_voice_listen";
    "keeper_voice_agent";
    "keeper_voice_sessions";
    "keeper_voice_session_start";
    "keeper_voice_session_end";
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
  | Public
  | Keeper
  | System

(** Public surface: tools visible from the default MCP tools/list endpoint. *)
let public_surface_tools =
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
    "masc_board_stats"; "masc_board_comment_vote";
    "masc_board_profile"; "masc_board_hearths";
    (* Agent discovery *)
    "masc_agents"; "masc_dashboard"; "masc_agent_card";
    "masc_agent_timeline";
    (* Utility *)
    "masc_tool_help"; "masc_web_search"; "masc_check";
    (* Production *)
    "masc_bounded_run"; "masc_recall_search";
    (* Verification *)
    "masc_verify_auto"; "masc_verify_handoff"; "masc_verify_pending";
    "masc_verify_request"; "masc_verify_status"; "masc_verify_submit";
  ]

(** Spawned agent tools: tools available to OAS-spawned agents. *)
let spawned_agent_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_broadcast"; "masc_join"; "masc_leave";
    "masc_who"; "masc_add_task"; "masc_heartbeat";
    "masc_messages";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
    "masc_handover_create"; "masc_handover_list"; "masc_handover_get";
    "masc_board_list"; "masc_board_post"; "masc_board_comment";
    "masc_board_vote"; "masc_board_get";
    "masc_tool_help"; "masc_web_search";
    "masc_note_add";
    "masc_code_delete"; "masc_code_edit"; "masc_code_git";
    "masc_code_shell"; "masc_code_write";
    "masc_deliver";
    "masc_verify_handoff"; "masc_workflow_guide";
  ]

(** Local worker tools: narrow subset for OAS local workers. *)
let local_worker_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next"; "masc_transition";
    "masc_add_task"; "masc_heartbeat";
    "masc_board_post"; "masc_board_list"; "masc_board_get";
    "masc_board_comment"; "masc_board_vote"; "masc_board_search";
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
    "masc_worktree_create"; "masc_worktree_remove"; "masc_worktree_list";
  ]

let session_min_tools =
  [
    "masc_status"; "masc_tasks"; "masc_claim_next";
    "masc_plan_set_task"; "masc_transition"; "masc_add_task";
    "masc_broadcast"; "masc_heartbeat";
  ]

let keeper_denied_tools =
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

let keeper_surface_tools = keeper_internal_tools

let dedupe_keep_order names =
  let seen = Hashtbl.create (List.length names) in
  List.filter
    (fun name ->
      if Hashtbl.mem seen name then
        false
      else (
        Hashtbl.replace seen name ();
        true))
    names

let hidden_callable_surface_tools =
  dedupe_keep_order (spawned_agent_tools @ local_worker_tools)
  |> List.filter (fun name -> not (List.mem name public_surface_tools))

let system_surface_tools =
  [
    "masc_room_delete"; "masc_force_leave";
    "masc_admin_reset"; "masc_admin_cleanup";
    "masc_gc_force"; "masc_config_set";
    "masc_reset";
    "masc_execute"; "masc_execute_dry_run";
    (* Session lifecycle / MCP protocol internals *)
    "masc_mcp_session"; "masc_suspend"; "masc_listen";
    "masc_init"; "masc_reset"; "masc_register_capabilities";
    "masc_set_room";
    (* Governance / concurrency control *)
    "masc_governance_set";
    "masc_lock"; "masc_unlock";
    (* Heartbeat system loop *)
    "masc_heartbeat_start"; "masc_heartbeat_stop";
    "masc_heartbeat_list"; "masc_heartbeat_result";
    (* Task lifecycle / agent evaluation *)
    "masc_cancel_task"; "masc_claim_task"; "masc_complete_task";
    "masc_release_task"; "masc_set_current_task";
    "masc_agent_fitness"; "masc_agent_relations";
    "masc_meta_cognition_snapshot"; "masc_consolidate_learning";
    "masc_find_by_capability"; "masc_get_metrics";
    "masc_select_agent"; "masc_agent_update"; "masc_task_history";
    (* Maintenance / misc admin *)
    "masc_cleanup_zombies"; "masc_gc"; "masc_compact_context";
    "masc_cancellation"; "masc_subscription"; "masc_progress";
    "masc_feature_flags"; "masc_pause_status";
    "masc_tool_stats"; "masc_tool_admin_snapshot"; "masc_tool_admin_update";
    "masc_keeper_tool_catalog"; "masc_config";
    (* Auth / operator / control *)
    "masc_auth_create_token";
    "masc_auth_disable"; "masc_auth_enable"; "masc_auth_list";
    "masc_auth_refresh"; "masc_auth_revoke"; "masc_auth_status";
    "masc_operator_snapshot"; "masc_operator_digest";
    "masc_operator_action"; "masc_operator_confirm";
    "masc_operator_judgment_write"; "masc_surface_audit";
    "masc_collaboration_evidence"; "masc_pause"; "masc_resume";
    "masc_runtime_verify";
    "masc_keeper_create_from_persona";
    (* Command plane *)
    "masc_dispatch_assign"; "masc_dispatch_escalate"; "masc_dispatch_plan";
    "masc_dispatch_rebalance"; "masc_dispatch_recall"; "masc_dispatch_tick";
    "masc_observe_alerts"; "masc_observe_capacity";
    "masc_observe_operations"; "masc_observe_swarm";
    "masc_observe_topology"; "masc_observe_traces";
    "masc_operation_checkpoint"; "masc_operation_finalize";
    "masc_operation_pause"; "masc_operation_resume";
    "masc_operation_start"; "masc_operation_status"; "masc_operation_stop";
    "masc_room_strategy_get"; "masc_room_strategy_set";
    "masc_unit_define"; "masc_unit_list";
    "masc_unit_reassign"; "masc_unit_reparent";
    "masc_detachment_list"; "masc_detachment_status";
    "masc_policy_status"; "masc_policy_approve";
    "masc_policy_deny"; "masc_policy_update";
    "masc_policy_freeze_unit"; "masc_policy_kill_switch";
  ]
  @ hidden_callable_surface_tools

(* ================================================================ *)
(* Surface query functions                                          *)
(* ================================================================ *)

let tools_for_surface = function
  | Public -> public_surface_tools
  | Keeper -> keeper_surface_tools
  | System -> system_surface_tools

let all_surfaces = [Public; Keeper; System]

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
  | Public -> "public"
  | Keeper -> "keeper"
  | System -> "system"
