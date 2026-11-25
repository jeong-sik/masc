(** Converged navigation model: 6 Workspaces, 1st-class Sub-Tabs (zero hidden
    submodes), Depth-1 Inspectors (Verification / Tool / Skill / Exact Run),
    8 Overlays, Left Navigation Sidebar Tree SSOT, and Focus Scope.

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
  | Keeper_trace
  | Keeper_memory
  | Keeper_work_sandbox
  | Keeper_config
  | Keeper_identity

type inspector =
  | Verification_inspector of string
  | Tool_inspector of string
  | Skill_inspector of string
  | Exact_run_inspector of string

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

type keeper_destructive_action =
  | Keeper_act_shutdown
  | Keeper_act_reset
  | Keeper_act_apply_purge
  | Keeper_act_delete_history

type inline_action_kind =
  | Btw_query
  | Gate_reject of string
  | Verification_reject of string
  | Harness_overrule of string
  | Task_cancel of string
  | Goal_drop of string
  | Schedule_form
  | Connector_form
  | Repo_add_form
  | Board_new_post
  | Board_goal_proposal
  | Goal_confirmation_proof
  | Memory_act_form
  | Wiki_edit_form
  | Fusion_launch_form
  | Runtime_assign_form
  | Setup_account_key_form
  | Setup_login_start_form
  | Board_comment of { post_id : string; parent_id : string option }
  | Github_token_form of string
  | Code_finder_form
  | Code_search_form
  | Runtime_lane_create
  | Runtime_lane_edit of {
      lane_id : string;
      exact_output : bool;
      opened_revision : string option;
    }
  | Runtime_lane_delete of {
      lane_id : string;
      opened_revision : string option;
    }
  | Task_create_form
  | Task_transition_form of { task_id : string }
  | Task_link_goal of { task_id : string }
  | Goal_upsert_form of string option
  | Board_delete_post of {
      post_id : string;
      title : string;
    }
  | Keeper_lifecycle_form of { keeper : string }
  | Keeper_purge_confirm of { keeper : string }
  | Addon_attach_form
  | Addon_detach_confirm of {
      instance_id : string;
      title : string;
    }
  | Addon_invoke_action of {
      instance_id : string;
      action_names : string list;
    }
  | Setup_login_input_form of { login_id : string }
  | Keeper_control_confirm of {
      keeper : string;
      action : keeper_destructive_action;
    }
  | Keeper_clear_form of string
  | Keeper_operator_note_form of string
  | Discord_reply_form of {
      keeper : string;
      chat_id : string;
      guild_id : string option;
      channel_id : string;
      message_id : string;
      workspace_base_path : string;
      workspace_masc_root : string;
    }
  | Tool_execute_form of { tool_name : string option; args_json : string }
  | Skill_create_form
  | Skill_edit_form of { reference : string }
  | Skill_delete_confirm of { reference : string }
  | Prompt_override_form of { key : string }
  | Preset_create_form
  | Runtime_param_set_form of { param_key : string }
  | Default_route_edit
  | Lane_rename_form of { lane : string }
  | Addon_decl_form of {
      file_name : string;
      mode : [ `Create | `Save ];
      expected_source_revision : string option;
    }
  | Addon_act_form of {
      instance_id : string;
      expected_incarnation : string;
    }
  | Browser_interact_form of {
      client_id : string;
      tab_id : int;
      expected_url : string option;
    }

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
  | Inspector_focused of inspector
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
val equal_inspector : inspector -> inspector -> bool
val equal_settings_tab : settings_tab -> settings_tab -> bool
val equal_queue_context_tab : queue_context_tab -> queue_context_tab -> bool
val equal_keeper_destructive_action :
  keeper_destructive_action -> keeper_destructive_action -> bool
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
