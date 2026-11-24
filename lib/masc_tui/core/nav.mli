(** Converged navigation model: 6 Workspaces, 1st-class Sub-Tabs (zero hidden
    submodes), 5 Dives, 7 Overlays, Left Navigation Sidebar Tree SSOT, and Focus Scope.

    Closed algebraic types with zero hidden string routes. *)

type workspace =
  | Pulse
  | Work
  | Knowledge
  | Keepers
  | Runtime
  | Infra

type work_tab =
  | Work_pipeline
  | Work_tasks
  | Work_schedules
  | Work_inbox
  | Work_candle_scorecard
  | Work_harness

type knowledge_tab =
  | Knowledge_board
  | Knowledge_wiki
  | Knowledge_artifacts
  | Knowledge_memory

type keepers_fleet_mode =
  | Fleet_companies
  | Fleet_attention
  | Fleet_pulse_wall

type runtime_tab =
  | Runtime_quotas_credits
  | Runtime_efficiency_spend
  | Runtime_failover_lanes
  | Runtime_fusion
  | Runtime_tools_usage
  | Runtime_connectors
  | Runtime_addons_browser

type infra_tab =
  | Infra_sandboxes
  | Infra_repos_changes
  | Infra_code
  | Infra_activity_logs

type keeper_tab =
  | Keeper_chat
  | Keeper_context
  | Keeper_tool_calls
  | Keeper_memory
  | Keeper_work_candle
  | Keeper_sandbox
  | Keeper_config
  | Keeper_logs
  | Keeper_identity

type work_dive_target =
  | Goal_dive of string
  | Task_dive of string
  | Verification_dive of string

type knowledge_dive_target =
  | Thread_dive of string
  | Wiki_dive of string
  | Artifact_dive of string
  | Memory_diff_dive of { keeper : string option; from_rev : int; to_rev : int }

type runtime_dive_target =
  | Tool_dive of string
  | Fusion_dive of string

type infra_dive_target =
  | Sandbox_dive of string
  | Lane_dive of string
  | Incident_dive of int
  | Runtime_trace_dive of string
  | Log_detail_dive of int

type dive =
  | Dive_keeper of { name : string; tab : keeper_tab }
  | Dive_work of work_dive_target
  | Dive_knowledge of knowledge_dive_target
  | Dive_runtime of runtime_dive_target
  | Dive_infra of infra_dive_target

type settings_tab =
  | Settings_general_ui
  | Settings_providers_models
  | Settings_routing_failover
  | Settings_keepers_companies
  | Settings_sandbox_ssh
  | Settings_voice_integrations
  | Settings_board_memory_candle

type queue_context_tab =
  | Drawer_queue
  | Drawer_context
  | Drawer_schedules

type inline_action_kind =
  | Btw_query
  | Gate_reject of string
  | Verification_reject of string
  | Harness_overrule of string
  | Task_cancel of string
  | Schedule_form
  | Connector_form
  | Repo_add_form
  | Board_new_post
  | Board_comment of { post_id : string; parent_id : string option }
  | Github_token_form of string
  | Code_finder_form
  | Code_search_form

type system_gate_kind =
  | Micro_viewport
  | Auth_gate
  | Server_offline
  | Media_viewer

type overlay =
  | Palette
  | Settings of settings_tab
  | Incidents
  | Queue_context of queue_context_tab
  | Inline_action of inline_action_kind
  | Ask_answer
  | Help
  | System_gate of system_gate_kind

type focus_scope =
  | Global
  | Workspace_focused of workspace
  | Dive_focused of dive
  | Composer_focused
  | Ask_choice_focused
  | Approval_strip_focused
  | Overlay_focused of overlay

val all_workspaces : workspace list
val workspace_index : workspace -> int
(** 1-based workspace number ([1..6]). *)

val workspace_of_index : int -> workspace option
(** Strict parser for [1..6]; returns [None] outside that range. *)

val workspace_label : workspace -> Say.t

val all_work_tabs : work_tab list
val work_tab_label : work_tab -> Say.t
val next_work_tab : work_tab -> work_tab
val prev_work_tab : work_tab -> work_tab

val all_knowledge_tabs : knowledge_tab list
val knowledge_tab_label : knowledge_tab -> Say.t
val next_knowledge_tab : knowledge_tab -> knowledge_tab
val prev_knowledge_tab : knowledge_tab -> knowledge_tab

val all_keepers_fleet_modes : keepers_fleet_mode list
val keepers_fleet_mode_label : keepers_fleet_mode -> Say.t
val next_keepers_fleet_mode : keepers_fleet_mode -> keepers_fleet_mode
val prev_keepers_fleet_mode : keepers_fleet_mode -> keepers_fleet_mode

val all_runtime_tabs : runtime_tab list
val runtime_tab_label : runtime_tab -> Say.t
val next_runtime_tab : runtime_tab -> runtime_tab
val prev_runtime_tab : runtime_tab -> runtime_tab

val all_infra_tabs : infra_tab list
val infra_tab_label : infra_tab -> Say.t
val next_infra_tab : infra_tab -> infra_tab
val prev_infra_tab : infra_tab -> infra_tab

val all_keeper_tabs : keeper_tab list
val keeper_tab_label : keeper_tab -> Say.t
val next_keeper_tab : keeper_tab -> keeper_tab
val prev_keeper_tab : keeper_tab -> keeper_tab

val all_settings_tabs : settings_tab list
val settings_tab_label : settings_tab -> Say.t
val next_settings_tab : settings_tab -> settings_tab
val prev_settings_tab : settings_tab -> settings_tab

val all_queue_context_tabs : queue_context_tab list
val queue_context_tab_label : queue_context_tab -> Say.t
val next_queue_context_tab : queue_context_tab -> queue_context_tab
val prev_queue_context_tab : queue_context_tab -> queue_context_tab

val equal_workspace : workspace -> workspace -> bool
val equal_work_tab : work_tab -> work_tab -> bool
val equal_knowledge_tab : knowledge_tab -> knowledge_tab -> bool
val equal_keepers_fleet_mode : keepers_fleet_mode -> keepers_fleet_mode -> bool
val equal_runtime_tab : runtime_tab -> runtime_tab -> bool
val equal_infra_tab : infra_tab -> infra_tab -> bool
val equal_keeper_tab : keeper_tab -> keeper_tab -> bool
val equal_work_dive_target : work_dive_target -> work_dive_target -> bool
val equal_knowledge_dive_target : knowledge_dive_target -> knowledge_dive_target -> bool
val equal_runtime_dive_target : runtime_dive_target -> runtime_dive_target -> bool
val equal_infra_dive_target : infra_dive_target -> infra_dive_target -> bool
val equal_dive : dive -> dive -> bool
val equal_settings_tab : settings_tab -> settings_tab -> bool
val equal_queue_context_tab : queue_context_tab -> queue_context_tab -> bool
val equal_inline_action_kind : inline_action_kind -> inline_action_kind -> bool
val equal_system_gate_kind : system_gate_kind -> system_gate_kind -> bool
val equal_overlay : overlay -> overlay -> bool
val equal_focus_scope : focus_scope -> focus_scope -> bool
(** Unified Left Navigation Sidebar & Palette Screen SSOT.
    Every reachable workspace, first-class sub-screen, and system overlay has
    exactly one canonical entry so operators never hunt across hidden submodes. *)

type menu_section =
  | Sec_overview
  | Sec_work
  | Sec_knowledge
  | Sec_fleet
  | Sec_runtime
  | Sec_infra
  | Sec_system

type menu_target =
  | Menu_pulse
  | Menu_work of work_tab
  | Menu_knowledge of knowledge_tab
  | Menu_keepers
  | Menu_keeper_tab of keeper_tab
  | Menu_runtime of runtime_tab
  | Menu_infra of infra_tab
  | Menu_settings
  | Menu_incidents
  | Menu_queue_context
  | Menu_help

type menu_item = {
  section : menu_section;
  target : menu_target;
  label : Say.t;
  shortcut : string option;
}

val all_menu_items : menu_item list
val menu_section_label : menu_section -> Say.t
val menu_section_shortcut : menu_section -> string option
val equal_menu_section : menu_section -> menu_section -> bool
val equal_menu_target : menu_target -> menu_target -> bool
val menu_item_index : menu_target -> int
val menu_item_of_index : int -> menu_item option
val is_overlay_menu_target : menu_target -> bool
