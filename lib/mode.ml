(** MASC Mode System - Category-based tool filtering

    Inspired by Serena MCP's switch_modes pattern.
    Every tool must be explicitly mapped to a category.
    Unmapped tools fall to Unknown and are excluded from all mode presets.
*)

(** Tool categories *)
type category =
  | Core        (* backward compat alias — expands to Core_Room + Core_Task + Core_Session + Core_Ops *)
  | Core_Room   (* room entry/exit: join, leave, room_create, rooms_list *)
  | Core_Task   (* task lifecycle: add_task, claim, transition, status *)
  | Core_Session (* team sessions: team_session_start/step/finalize *)
  | Core_Ops    (* advanced: operations, dispatch, policy, observe, operator, run, units, etc. *)
  | Comm        (* broadcast, messages, lock, unlock, listen, who, reset, lodge_* *)
  | Portal      (* portal_open, portal_send, portal_close, portal_status *)
  | Worktree    (* worktree_create, worktree_remove, worktree_list *)
  | Code        (* code_search, code_symbols, code_read *)
  | Health      (* heartbeat, cache, tempo, relay, mitosis, gc, metrics, verify, error, episode *)
  | Discovery   (* register_capabilities, find_by_capability, agent_card, fitness *)
  | Voting      (* vote_create, vote_cast, vote_status, votes *)
  | Interrupt   (* interrupt, approve, reject, pending_interrupts, branch *)
  | Cost        (* cost_log, cost_report *)
  | Auth        (* auth_*, audit_*, governance_* *)
  | RateLimit   (* rate_limit_status, rate_limit_config *)
  | Encryption  (* encryption_*, generate_key *)
  | Board       (* board_post, board_list, board_get, board_comment, board_vote, ... *)
  | Plan        (* plan_*, goal_*, intent_* *)
  | Consensus   (* debate_*, consensus_*, walph_*, convo_*, decision_*, council_status *)
  | Ecosystem   (* keeper_*, mdal_*, handover_*, library_* *)
  | Voice       (* masc_voice_*: TTS, STT, sessions, conferences *)
  | TRPG        (* masc_trpg_*, trpg_* *)
  | Unknown     (* unmapped namespace/tool *)

(** Mode presets *)
type mode =
  | Minimal   (* core_room, core_task, health *)
  | Standard  (* core, comm, worktree, health, plan, board, consensus, voice *)
  | Parallel  (* core, comm, portal, worktree, health, discovery, plan, board, consensus, voting, interrupt, voice *)
  | Coding    (* core, worktree, code, health, plan *)
  | Full      (* all categories *)
  | Solo      (* core_room, core_task, worktree *)
  | Agent     (* core_room, core_task, worktree — 20 tools, PR #814 sweet spot *)
  | Custom    (* user-defined categories *)

(** Category to string conversion *)
let category_to_string = function
  | Core -> "core"
  | Core_Room -> "core_room"
  | Core_Task -> "core_task"
  | Core_Session -> "core_session"
  | Core_Ops -> "core_ops"
  | Comm -> "comm"
  | Portal -> "portal"
  | Worktree -> "worktree"
  | Code -> "code"
  | Health -> "health"
  | Discovery -> "discovery"
  | Voting -> "voting"
  | Interrupt -> "interrupt"
  | Cost -> "cost"
  | Auth -> "auth"
  | RateLimit -> "ratelimit"
  | Encryption -> "encryption"
  | Board -> "board"
  | Plan -> "plan"
  | Consensus -> "consensus"
  | Ecosystem -> "ecosystem"
  | Voice -> "voice"
  | TRPG -> "trpg"
  | Unknown -> "unknown"

(** String to category conversion *)
let category_of_string = function
  | "core" -> Some Core
  | "core_room" -> Some Core_Room
  | "core_task" -> Some Core_Task
  | "core_session" -> Some Core_Session
  | "core_ops" -> Some Core_Ops
  | "comm" -> Some Comm
  | "portal" -> Some Portal
  | "worktree" -> Some Worktree
  | "code" -> Some Code
  | "health" -> Some Health
  | "discovery" -> Some Discovery
  | "voting" -> Some Voting
  | "interrupt" -> Some Interrupt
  | "cost" -> Some Cost
  | "auth" -> Some Auth
  | "ratelimit" -> Some RateLimit
  | "encryption" -> Some Encryption
  | "board" -> Some Board
  | "plan" -> Some Plan
  | "consensus" -> Some Consensus
  | "ecosystem" -> Some Ecosystem
  | "voice" -> Some Voice
  | "trpg" -> Some TRPG
  | _ -> None

(** Mode to string conversion *)
let mode_to_string = function
  | Minimal -> "minimal"
  | Standard -> "standard"
  | Parallel -> "parallel"
  | Coding -> "coding"
  | Full -> "full"
  | Solo -> "solo"
  | Agent -> "agent"
  | Custom -> "custom"

(** String to mode conversion *)
let mode_of_string = function
  | "minimal" -> Some Minimal
  | "standard" -> Some Standard
  | "parallel" -> Some Parallel
  | "coding" -> Some Coding
  | "full" -> Some Full
  | "solo" -> Some Solo
  | "agent" -> Some Agent
  | "custom" -> Some Custom
  | _ -> None

(** Core sub-categories expanded *)
let core_all = [Core_Room; Core_Task; Core_Session; Core_Ops]

(** All categories (Unknown intentionally excluded — unmapped tools are blocked) *)
let all_categories =
  core_all @ [
  Comm; Portal; Worktree; Code; Health; Discovery;
  Voting; Interrupt; Cost; Auth; RateLimit; Encryption;
  Board; Plan; Consensus; Ecosystem; Voice; TRPG
]

(** Categories for each mode preset *)
let categories_for_mode = function
  | Minimal -> [Core_Room; Core_Task; Health]
  | Standard -> core_all @ [Comm; Worktree; Health; Plan; Board; Consensus; Voice]
  | Parallel -> core_all @ [Comm; Portal; Worktree; Health; Discovery;
                 Plan; Board; Consensus; Voting; Interrupt; Voice]
  | Coding -> core_all @ [Worktree; Code; Health; Plan; Consensus]
  | Full -> all_categories
  | Solo -> [Core_Room; Core_Task; Worktree]
  | Agent -> [Core_Room; Core_Task; Worktree; Board; Comm]
  | Custom -> [] (* Will be loaded from config *)

(** Tool name to category mapping.

    Every tool must be explicitly listed here. New tools that are not mapped
    fall to Unknown and will not appear in any mode preset. This is intentional:
    it forces the developer to choose a category when adding a new tool. *)
let tool_category tool_name =
  match tool_name with

  (* ── Core_Room: room entry/exit, essential coordination ── *)
  | "masc_start" | "masc_set_room" | "masc_init" | "masc_join" | "masc_leave"
  | "masc_room_create" | "masc_room_enter" | "masc_rooms_list"
  | "masc_discover_tools" -> Core_Room

  (* ── Core_Task: task lifecycle ── *)
  | "masc_add_task" | "masc_batch_add_tasks"
  | "masc_claim"
  | "masc_tasks" | "masc_claim_next"
  | "masc_update_priority" | "masc_transition"
  | "masc_task_history"
  | "masc_fire_task"
  | "masc_status" | "masc_workflow_guide" | "masc_check"
  | "masc_room_strategy_get" | "masc_room_strategy_set"
  (* Mode management - always available via is_tool_enabled bypass *)
  | "masc_switch_mode" | "masc_get_config"
  | "masc_tool_enable" | "masc_tool_disable" -> Core_Task

  (* ── Core_Session: team session orchestration (11 tools) ── *)
  | "masc_team_session_start" | "masc_team_session_step"
  | "masc_team_session_status" | "masc_team_session_finalize"
  | "masc_team_session_stop" | "masc_team_session_report"
  | "masc_team_session_list" | "masc_team_session_compare"
  | "masc_team_session_events"
  | "masc_team_session_prove" | "masc_team_session_verify_trace" -> Core_Session

  (* ── Core_Ops: advanced orchestration, run pipeline, policy, observe (36 tools) ── *)
  | "masc_archive_view" | "masc_dashboard" | "masc_agent_timeline"
  (* Run pipeline *)
  | "masc_run_init" | "masc_run_plan" | "masc_run_log"
  | "masc_run_deliverable" | "masc_run_get" | "masc_run_list"
  (* MODEL runtime — canonical + backward-compat aliases *)
  | "masc_local_runtime_models" | "masc_llama_models"
  | "masc_local_runtime_status" | "masc_llama_runtime_status"
  | "masc_runtime_verify"
  | "masc_local_runtime_bench" | "masc_llama_runtime_bench"
  | "masc_model_catalog"
  (* Units *)
  | "masc_unit_define" | "masc_unit_list"
  | "masc_unit_reparent" | "masc_unit_reassign"
  (* Operations *)
  | "masc_operation_start" | "masc_operation_status"
  | "masc_operation_checkpoint" | "masc_operation_pause"
  | "masc_operation_resume" | "masc_operation_stop"
  | "masc_operation_finalize"
  (* Dispatch *)
  | "masc_dispatch_plan" | "masc_dispatch_assign"
  | "masc_dispatch_rebalance" | "masc_dispatch_escalate"
  | "masc_dispatch_recall" | "masc_dispatch_tick"
  (* Policy *)
  | "masc_policy_status" | "masc_policy_approve"
  | "masc_policy_deny" | "masc_policy_update"
  | "masc_policy_freeze_unit" | "masc_policy_kill_switch"
  (* Observe *)
  | "masc_observe_topology" | "masc_observe_operations"
  | "masc_observe_swarm" | "masc_observe_capacity" | "masc_observe_alerts"
  | "masc_observe_traces"
  (* Operator *)
  | "masc_operator_snapshot" | "masc_operator_digest"
  | "masc_operator_action" | "masc_operator_confirm"
  | "masc_operator_judgment_write" | "masc_operator_judgment_latest"
  (* Detachment *)
  | "masc_detachment_list" | "masc_detachment_status"
  (* Execute *)
  | "masc_execute" | "masc_execute_dry_run"
  | "masc_bounded_run" | "masc_deliver" | "masc_route"
  (* Chain *)
  | "masc_chain_run_get" | "masc_chain_snapshot"
  (* Hat *)
  | "masc_hat_status" | "masc_hat_wear"
  (* Pause/resume *)
  | "masc_pause" | "masc_pause_status" | "masc_resume" | "masc_suspend"
  | "masc_compact_context"
  | "masc_tool_help" | "masc_tool_admin_snapshot" | "masc_keeper_tool_catalog" -> Core_Ops

  (* ── Communication ── *)
  | "masc_broadcast" | "masc_messages"
  | "masc_listen" | "masc_who" | "masc_reset"
  | "masc_subscription" | "masc_progress"
  | "masc_lock" | "masc_unlock"
  | "masc_note_add" | "masc_poll_events"
  (* Social feed (hidden in tool_catalog but still categorized) *)
  | "masc_post_create" | "masc_post_get" | "masc_post_list"
  | "masc_comment_add" | "masc_comment_list"
  | "masc_vote" -> Comm

  (* ── Portal A2A ── *)
  | "masc_portal_open" | "masc_portal_send" | "masc_portal_close"
  | "masc_portal_status" -> Portal

  (* ── A2A delegation ── *)
  | "masc_a2a_delegate" | "masc_a2a_discover"
  | "masc_a2a_query_skill" | "masc_a2a_subscribe"
  | "masc_a2a_unsubscribe" -> Portal

  (* ── Git worktree ── *)
  | "masc_worktree_create" | "masc_worktree_remove"
  | "masc_worktree_list" -> Worktree

  (* ── Health & maintenance ── *)
  | "masc_heartbeat" | "masc_cleanup_zombies" | "masc_gc"
  | "masc_agents"
  | "masc_cache_set" | "masc_cache_get" | "masc_cache_delete"
  | "masc_cache_list" | "masc_cache_clear" | "masc_cache_stats"
  | "masc_tempo" | "masc_tempo_get" | "masc_tempo_set"
  | "masc_tempo_adjust" | "masc_tempo_reset"
  | "masc_mcp_session" | "masc_cancellation"
  | "masc_relay_status" | "masc_relay_checkpoint"
  | "masc_relay_now" | "masc_relay_smart_check"
  | "masc_mitosis_status" | "masc_mitosis_all" | "masc_mitosis_pool"
  | "masc_mitosis_divide" | "masc_mitosis_check" | "masc_mitosis_record"
  | "masc_mitosis_prepare" | "masc_mitosis_handoff" | "masc_memento_mori"
  | "masc_verify_handoff"
  (* Additional health tools *)
  | "masc_circuit_status"
  | "masc_episode_flush" | "masc_episode_list"
  | "masc_error_add" | "masc_error_resolve"
  | "masc_heartbeat_list" | "masc_heartbeat_result"
  | "masc_heartbeat_start" | "masc_heartbeat_stop"
  | "masc_metrics_compare" | "masc_metrics_record"
  | "masc_recall_search"
  | "masc_tool_stats"
  | "masc_notification_count" | "masc_check_notifications"
  | "masc_consume_notifications"
  | "masc_housekeep_scan" | "masc_housekeep_delete" | "masc_housekeep_prune"
  (* Verification tools *)
  | "masc_verify_auto" | "masc_verify_pending"
  | "masc_verify_request" | "masc_verify_status"
  | "masc_verify_submit" -> Health

  (* ── Agent discovery ── *)
  | "masc_register_capabilities" | "masc_find_by_capability"
  | "masc_agent_update" | "masc_agent_card"
  | "masc_get_metrics" | "masc_agent_fitness" | "masc_select_agent"
  | "masc_collaboration_graph" | "masc_consolidate_learning"
  | "masc_self_introspect" | "masc_agent_relations" -> Discovery

  (* ── Voting ── *)
  | "masc_vote_create" | "masc_vote_cast" | "masc_vote_status"
  | "masc_votes" -> Voting

  (* ── Interrupt/checkpoint ── *)
  | "masc_interrupt" | "masc_approve" | "masc_reject"
  | "masc_pending_interrupts" | "masc_branch" -> Interrupt

  (* ── Cost tracking ── *)
  | "masc_cost_log" | "masc_cost_report" -> Cost

  (* ── Authentication & governance ── *)
  | "masc_auth_enable" | "masc_auth_disable" | "masc_auth_status"
  | "masc_auth_create_token" | "masc_auth_refresh" | "masc_auth_revoke"
  | "masc_auth_list" | "masc_tool_admin_update"
  | "masc_audit_query" | "masc_audit_stats" | "masc_audit_trail"
  | "masc_governance_set" | "masc_governance_report"
  | "masc_tool_grant" | "masc_tool_revoke" | "masc_tool_list" -> Auth

  (* ── Rate limiting ── *)
  | "masc_rate_limit_status" | "masc_rate_limit_config" -> RateLimit

  (* ── Encryption ── *)
  | "masc_encryption_status" | "masc_encryption_enable"
  | "masc_encryption_disable" | "masc_generate_key" -> Encryption

  (* ── Code navigation + editing ── *)
  | "masc_code_search" | "masc_code_symbols" | "masc_code_read"
  | "masc_code_write" | "masc_code_edit" | "masc_code_delete"
  | "masc_code_shell" | "masc_code_git"
  | "masc_code_swarm_plan" | "masc_code_swarm_verify" | "masc_code_swarm_merge" -> Code

  (* ── Board ── *)
  | "masc_board_post" | "masc_board_list" | "masc_board_get"
  | "masc_board_comment" | "masc_board_comment_vote"
  | "masc_board_vote" | "masc_board_hearths"
  | "masc_board_search" | "masc_board_stats"
  | "masc_board_profile" | "masc_board_migrate" -> Board

  (* ── Plan & Goal management ── *)
  | "masc_plan_init" | "masc_plan_get" | "masc_plan_get_task"
  | "masc_plan_set_task" | "masc_plan_update" | "masc_plan_clear_task"
  | "masc_goal_upsert" | "masc_goal_list" | "masc_goal_snapshot"
  | "masc_goal_dispatch" | "masc_goal_refresh" | "masc_goal_review"
  | "masc_intent_create" | "masc_intent_status"
  | "masc_intent_forecast" | "masc_intent_update" -> Plan

  (* ── Governance V2: petitions, rulings, WALPH, convo, decision ── *)
  (* Debate & consensus tools removed in v2.90.0 *)
  | "masc_petition_submit" | "masc_case_brief_submit"
  | "masc_cases" | "masc_case_status"
  | "masc_ruling_status" | "masc_execution_orders"
  | "masc_walph_control" | "masc_walph_loop"
  | "masc_walph_natural" | "masc_walph_status"
  | "masc_governance_status"
  | "masc_governance_feed" | "masc_runtime_params" | "masc_set_param"
  | "masc_convo_start" | "masc_convo_reply" | "masc_convo_get"
  | "masc_convo_list" | "masc_convo_conclude" -> Consensus

  (* ── Ecosystem: keeper, MDAL, autoresearch, handover, library ── *)
  (* Keeper read-only status surfaces *)
  | "masc_keeper_status" | "masc_keeper_list"
  | "masc_persistent_agent_status" | "masc_persistent_agent_list"
  | "masc_keeper_trajectory" | "masc_persistent_agent_trajectory"
  | "masc_keeper_eval" | "masc_persistent_agent_eval" -> Health
  (* Keeper *)
  | "masc_persona_list" | "masc_keeper_create_from_persona"
  | "masc_keeper_up" | "masc_keeper_down"
  | "masc_keeper_msg"
  | "masc_keeper_model_set" | "masc_keeper_policy_set"
  | "masc_keeper_feedback_record" | "masc_keeper_dataset_export"
  | "masc_keeper_action_explain" | "masc_keeper_eval_replay"
  | "masc_persistent_agent_create_from_persona"
  | "masc_persistent_agent_up" | "masc_persistent_agent_down"
  | "masc_persistent_agent_msg"
  | "masc_persistent_agent_model_set" | "masc_persistent_agent_policy_set"
  | "masc_persistent_agent_feedback_record"
  | "masc_persistent_agent_dataset_export"
  | "masc_persistent_agent_action_explain"
  | "masc_persistent_agent_eval_replay"
  | "masc_keeper_goals"
  | "masc_keeper_autonomy"
  | "masc_persistent_agent_goals"
  | "masc_persistent_agent_autonomy"
  (* MDAL *)
  | "masc_mdal_start" | "masc_mdal_iterate"
  | "masc_mdal_status" | "masc_mdal_stop"
  | "masc_mdal_swarm_start" | "masc_mdal_swarm_status"
  (* Autoresearch *)
  | "masc_autoresearch_start" | "masc_autoresearch_swarm_start"
  | "masc_autoresearch_status" | "masc_autoresearch_stop"
  | "masc_autoresearch_inject" | "masc_autoresearch_cycle"
  | "masc_autoresearch_record_finding" | "masc_autoresearch_search_findings"
  (* Handover *)
  | "masc_handover_create" | "masc_handover_get"
  | "masc_handover_list" | "masc_handover_claim"
  | "masc_handover_claim_and_spawn"
  (* Library *)
  | "masc_library_add" | "masc_library_list" | "masc_library_read"
  | "masc_library_search" | "masc_library_promote"
  (* Spawn *)
  | "masc_spawn" -> Ecosystem

  (* ── Voice: TTS, STT, sessions, conferences ── *)
  | "masc_voice_speak" | "masc_voice_session_start"
  | "masc_voice_session_end" | "masc_voice_sessions"
  | "masc_voice_agent" | "masc_voice_transcript"
  | "masc_voice_conference_start" | "masc_voice_conference_end" -> Voice

  (* ── TRPG: archived (#1668), no active schemas ── *)

  (* ── Deprecated/archived tools (hidden via tool_catalog, excluded from presets) ── *)

  (* ── Prefix-based fallbacks for legacy dot-separated names ── *)
  | _ when String.starts_with ~prefix:"decision." tool_name -> Consensus
  | _ when String.starts_with ~prefix:"decision_" tool_name -> Consensus
  | _ when String.starts_with ~prefix:"experiment." tool_name -> Ecosystem
  | _ when String.starts_with ~prefix:"experiment_" tool_name -> Ecosystem
  (* trpg.* and masc_trpg_* prefix fallbacks removed — archived (#1668) *)
  | _ when String.starts_with ~prefix:"client." tool_name -> Core_Ops
  | _ when String.starts_with ~prefix:"client_" tool_name -> Core_Ops

  (* Unmapped tools are excluded from all mode presets.
     Add new tools explicitly above to make them available. *)
  | _ -> Unknown

(** Per-session extra enabled tools (progressive disclosure).
    Tools in this set bypass mode filtering. *)
let extra_enabled_tools : (string, unit) Hashtbl.t = Hashtbl.create 16

let tool_enable name =
  Hashtbl.replace extra_enabled_tools name ()

let tool_disable name =
  Hashtbl.remove extra_enabled_tools name

let tool_enable_list () =
  Hashtbl.fold (fun name () acc -> name :: acc) extra_enabled_tools []

let tool_enable_clear () =
  Hashtbl.clear extra_enabled_tools

(** Check if a tool is enabled for given categories.
    Core is a virtual super-category — if enabled_categories contains Core,
    all Core sub-categories are allowed.
    Extra-enabled tools bypass category filtering. *)
let is_tool_enabled enabled_categories tool_name =
  if tool_name = "masc_switch_mode" || tool_name = "masc_get_config"
     || tool_name = "masc_tool_enable" || tool_name = "masc_tool_disable" then
    true
  else if Hashtbl.mem extra_enabled_tools tool_name then
    true
  else
    match tool_category tool_name with
    | Unknown -> false
    | (Core_Room | Core_Task | Core_Session | Core_Ops) as cat ->
        List.mem cat enabled_categories || List.mem Core enabled_categories
    | cat -> List.mem cat enabled_categories

(** Mode descriptions for help text *)
let mode_description = function
  | Minimal -> "Room + task + health only (~20 tools)"
  | Standard -> "Core, communication, worktree, health, plan, board, consensus, and voice"
  | Parallel -> "Multi-agent: adds portal, discovery, plan, board, consensus, voting, interrupt, and voice"
  | Coding -> "Core, worktree, code navigation, health, plan, and consensus for agent development"
  | Full -> "All categories enabled (~322 tools)"
  | Solo -> "Room + task + worktree (~23 tools)"
  | Agent -> "Focused agent: room + task + worktree + board + comm (~30 tools)"
  | Custom -> "User-defined category set"

(** Category descriptions *)
let category_description = function
  | Core -> "All core sub-categories (room + task + session + ops)"
  | Core_Room -> "Room entry, exit, and space management (7 tools)"
  | Core_Task -> "Task lifecycle: add, claim, transition, status (15 tools)"
  | Core_Session -> "Team session orchestration (11 tools)"
  | Core_Ops -> "Advanced: operations, dispatch, policy, observe, operator (36 tools)"
  | Comm -> "Communication: broadcast, messages, listen, lodge"
  | Portal -> "A2A direct messaging and delegation"
  | Worktree -> "Git worktrees: create, list, remove"
  | Code -> "Code navigation: search, symbols, read"
  | Health -> "Maintenance: heartbeat, cache, tempo, relay, mitosis, gc, metrics, verify"
  | Discovery -> "Agent discovery, fitness, collaboration graph"
  | Voting -> "Room voting: create, cast, status"
  | Interrupt -> "Checkpoints: interrupt, approve, reject, branch"
  | Cost -> "Cost tracking: log, report"
  | Auth -> "Authentication, audit, governance"
  | RateLimit -> "Rate limiting: status, config"
  | Encryption -> "Data protection: enable, generate_key"
  | Board -> "Agent board: posts, comments, votes, search"
  | Plan -> "Plan and goal management: plan_*, goal_*, intent_*"
  | Consensus -> "Multi-agent consensus: debate, WALPH, convo, decision"
  | Ecosystem -> "Agent lifecycle: keeper, MDAL, handover, library"
  | Voice -> "Voice bridge: TTS, STT, sessions, conferences (8 tools)"
  | TRPG -> "Tabletop RPG engine: sessions, actors, dice, quests"
  | Unknown -> "Unmapped tool (excluded from all presets)"

(** JSON serialization *)
let categories_to_json cats =
  `List (List.map (fun c -> `String (category_to_string c)) cats)

let categories_of_json json =
  match json with
  | `List items ->
    List.filter_map (fun item ->
      match item with
      | `String s -> category_of_string s
      | _ -> None
    ) items
  | _ -> []
