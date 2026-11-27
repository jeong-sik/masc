open Masc_tui_core
open Masc_tui_keymap

let route_access_of_get_request : Cmd.get_request -> Rbac.route_access =
  function
  | Cmd.Get_health -> Rbac.Always_public
  | Cmd.Get_auth_whoami -> Rbac.Multi_account_whoami_probe
  | Cmd.Get_dashboard_shell -> Rbac.Single_user_shell_probe
  (* Bridged Workspace_read (SU Public_read/CanReadState + MA Workspace_read) *)
  | Cmd.Get_planning
  | Cmd.Get_schedules _
  | Cmd.Get_candle_ledger _
  | Cmd.Get_wiki_index _
  | Cmd.Get_wiki_page _
  | Cmd.Get_wiki_log _
  | Cmd.Get_wiki_search _
  | Cmd.Get_wiki_lint
  | Cmd.Get_world_memory
  | Cmd.Get_runtime_resolved
  | Cmd.Get_tools_catalog _
  | Cmd.Get_verification_runs
  | Cmd.Get_goal_verification_runs ->
      Rbac.Workspace_read
  | Cmd.Get_memory_diff { keeper; _ } ->
      Rbac.Memory_diff_read { keeper_scoped = Option.is_some keeper }
  | Cmd.Get_keeper_sandbox _ -> Rbac.Own_keeper_sandbox_read
  (* Dual-mode own-provider route: SU Token_permission CanAdmin, MA Manage_own_provider *)
  | Cmd.Get_setup_login_status _ -> Rbac.Own_provider_manage
  (* Dual-mode SU read / MA Admin_only browser session *)
  | Cmd.Get_sandboxes
  | Cmd.Get_system_logs _ ->
      Rbac.Su_read_ma_admin
  (* Bridged token-admin reads: SU Token_permission CanAdmin + MA Admin_only browser session *)
  | Cmd.Get_config_schema _
  | Cmd.Get_standalone_lanes
  | Cmd.Get_exact_lane_runs _
  | Cmd.Get_exact_lane_run_detail _ ->
      Rbac.Bridged_token_admin
  (* Single-user Token_permission CanReadState reads (404 in MA) *)
  | Cmd.Get_tui_preferences
  | Cmd.Get_keeper_sandbox_logs _
  | Cmd.Get_efficiency _
  | Cmd.Get_keeper_turn_records _
  | Cmd.Get_keeper_context_turn_records _
  | Cmd.Get_keeper_metrics _
  | Cmd.Get_keeper_cache_outcome _
  | Cmd.Get_keeper_memory_os_internals _ ->
      Rbac.Single_user_token_read
  (* Single-user Token_permission CanAdmin reads (404 in MA) *)
  | Cmd.Get_keeper_checkpoints _
  | Cmd.Get_github_identity _
  | Cmd.Get_keeper_provider_input _
  | Cmd.Get_keeper_provider_input_part _
  | Cmd.Get_keeper_memory_journal _
  | Cmd.Get_keeper_memory_activity _
  | Cmd.Get_keeper_memory_facts _
  | Cmd.Get_keeper_tool_calls _
  | Cmd.Get_keeper_tool_result _
  | Cmd.Get_chat_operation_events _
  | Cmd.Get_keeper_next_request _
  | Cmd.Get_oauth_attempt_status _
  | Cmd.Get_goal_confirmation _
  | Cmd.Get_verification_evidence _
  | Cmd.Get_late_approval_attempts
  | Cmd.Get_artifacts _
  | Cmd.Get_artifact_checks
  | Cmd.Get_runtime_config_raw
  | Cmd.Get_setup_inventory
  | Cmd.Get_runtime_metrics
  | Cmd.Get_lanes_inventory
  | Cmd.Get_fusion_config
  | Cmd.Get_skill_editor_sources
  | Cmd.Get_skill_editor_tools
  | Cmd.Get_async_requests
  | Cmd.Get_repository_activity _ ->
      Rbac.Single_user_token_admin_only
  (* Single-user Public_read / CanReadState / Read_auth reads (404 in MA) *)
  | Cmd.Get_keepers_roster
  | Cmd.Get_keeper_turns
  | Cmd.Get_chat_history _
  | Cmd.Get_chat_queue _
  | Cmd.Get_chat_status _
  | Cmd.Get_keeper_turn_transcript _
  | Cmd.Get_keeper_tool_stats _
  | Cmd.Get_keeper_runtime_trace _
  | Cmd.Get_keeper_turn_flow _
  | Cmd.Get_keeper_operator_note _
  | Cmd.Get_keeper_waiting_inventory _
  | Cmd.Get_keeper_board_attention_quarantines _
  | Cmd.Get_board_quarantines _
  | Cmd.Get_oauth_providers
  | Cmd.Get_oauth_attached_tools _
  | Cmd.Get_keeper_memory_health _
  | Cmd.Get_verifications _
  | Cmd.Get_asks _
  | Cmd.Get_tool_approvals
  | Cmd.Get_gate_pending
  | Cmd.Get_tool_approval_modes
  | Cmd.Get_gate_tool_events _
  | Cmd.Get_harness_health
  | Cmd.Get_verification_summary
  | Cmd.Get_verification_specs
  | Cmd.Get_verification_tlc_results
  | Cmd.Get_board_feed _
  | Cmd.Get_board_hearths
  | Cmd.Get_board_thread _
  | Cmd.Get_artifact_detail _
  | Cmd.Get_workspace_memory_ledger
  | Cmd.Get_workspace_memory_context
  | Cmd.Get_provider_usage _
  | Cmd.Get_keeper_costs _
  | Cmd.Get_models_metrics _
  | Cmd.Get_runtime_probe _
  | Cmd.Get_fusion_runs
  | Cmd.Get_fusion_run_detail _
  | Cmd.Get_fusion_board_evidence _
  | Cmd.Get_tool_series _
  | Cmd.Get_tool_series_filtered _
  | Cmd.Get_tool_quality _
  | Cmd.Get_skills
  | Cmd.Get_presets
  | Cmd.Get_preset_show _
  | Cmd.Get_runtime_params
  | Cmd.Get_connectors
  | Cmd.Get_connector_names _
  | Cmd.Get_browser_lane
  | Cmd.Get_lane_addons
  | Cmd.Get_lane_addon_asks _
  | Cmd.Get_lane_addon_declaration _
  | Cmd.Get_addon_package_catalog _
  | Cmd.Get_addon_package_preview _
  | Cmd.Get_lane_addon_action_status _
  | Cmd.Get_lane_addon_slice _
  | Cmd.Get_mcp_clients
  | Cmd.Get_prompts
  | Cmd.Get_activity_events _
  | Cmd.Get_repositories
  | Cmd.Get_repository_pulls
  | Cmd.Get_repository_detail _
  | Cmd.Get_workspace_children _
  | Cmd.Get_workspace_files _
  | Cmd.Get_workspace_search _
  | Cmd.Get_workspace_file _
  | Cmd.Get_git_branches _
  | Cmd.Get_git_worktrees _
  | Cmd.Get_git_status _
  | Cmd.Get_git_blame _
  | Cmd.Get_git_log _
  | Cmd.Get_git_diff _ ->
      Rbac.Single_user_read

let route_access_of_post_request : Cmd.post_request -> Rbac.route_access =
  function
  (* Bridged token-admin mutations: SU Token_permission CanAdmin + MA Admin_only session *)
  | Cmd.Post_sandbox_probe _
  | Cmd.Post_config_patch _ ->
      Rbac.Bridged_token_admin
  (* Dual-mode own-provider mutations: SU Token_permission CanAdmin, MA Manage_own_provider *)
  | Cmd.Post_setup_login_start _
  | Cmd.Post_setup_login_input _ ->
      Rbac.Own_provider_manage
  (* Single-user read-only POST queries (CanReadState; 404 in MA) *)
  | Cmd.Post_browser_tabs _
  | Cmd.Post_browser_scene _
  | Cmd.Post_browser_screenshot _ ->
      Rbac.Single_user_read
  (* Single-user worker-allowed writes (CanBroadcast/CanVote/CanAddTask/CanClaimTask/CanCompleteTask; 404 in MA) *)
  | Cmd.Post_goal_transition _
  | Cmd.Post_goal_upsert _
  | Cmd.Post_task_create _
  | Cmd.Post_task_transition _
  | Cmd.Post_schedule_create _
  | Cmd.Post_board_create _
  | Cmd.Post_board_comment _
  | Cmd.Post_board_vote _
  | Cmd.Post_board_comment_vote _
  | Cmd.Post_mcp_tools_list _
  | Cmd.Post_fusion_launch _
  | Cmd.Post_keeper_turn_interrupt _
  | Cmd.Post_connector_bind _
  | Cmd.Post_connector_unbind _
  | Cmd.Post_lane_addon_attach _
  | Cmd.Post_lane_addon_detach _
  | Cmd.Post_lane_addon_action _
  | Cmd.Post_lane_addon_declaration_save _
  | Cmd.Post_lane_addon_observe _
  | Cmd.Post_lane_addon_evidence _
  | Cmd.Post_lane_addon_act _ ->
      Rbac.Single_user_write
  (* Single-user Tool/Tool_actor admin_tool mutations (allows loopback auth_enabled=false Admin; 404 in MA) *)
  | Cmd.Post_ask_answer _
  | Cmd.Post_tool_approval _
  | Cmd.Post_keeper_tool_approval_mode _
  | Cmd.Post_lane_addon_ask_answer _
  | Cmd.Post_lane_addon_retain _
  | Cmd.Post_prompt_override _
  | Cmd.Post_runtime_param_set _
  | Cmd.Post_runtime_param_clear _ ->
      Rbac.Single_user_role_admin
  (* Single-user Token_permission CanAdmin mutations (404 in MA) *)
  | Cmd.Post_tui_preference _
  | Cmd.Post_gate_resolution _
  | Cmd.Post_goal_confirmation _
  | Cmd.Post_verification_verdict _
  | Cmd.Post_memory_act _
  | Cmd.Post_runtime_assignment _
  | Cmd.Post_runtime_default_route _
  | Cmd.Post_runtime_lane_create _
  | Cmd.Post_runtime_lane_update _
  | Cmd.Post_runtime_lane_delete _
  | Cmd.Post_setup_account_key _
  | Cmd.Post_artifact_check _
  | Cmd.Post_artifact_share _
  | Cmd.Post_repo_add _
  | Cmd.Post_task_cancel _
  | Cmd.Post_harness_overrule _
  | Cmd.Post_oauth_login _
  | Cmd.Post_oauth_identity_refresh _
  | Cmd.Post_oauth_identity_switch _
  | Cmd.Post_oauth_disconnect _
  | Cmd.Post_board_recovery _
  | Cmd.Post_github_token _
  | Cmd.Post_task_link_goal _
  | Cmd.Post_board_pin _
  | Cmd.Post_board_delete _
  | Cmd.Post_keeper_lifecycle _
  | Cmd.Post_keeper_purge _
  | Cmd.Post_keeper_control_lifecycle _
  | Cmd.Post_keeper_clear _
  | Cmd.Post_keeper_directive _
  | Cmd.Post_keeper_checkpoints _
  | Cmd.Post_discord_reply _
  | Cmd.Post_keeper_operator_note _
  | Cmd.Post_keeper_run_next _
  | Cmd.Post_gate_resolution_policy _
  | Cmd.Post_gate_mode _
  | Cmd.Post_gate_rule_delete _
  | Cmd.Post_gate_retry _
  | Cmd.Post_hitl_ack_uncertain _
  | Cmd.Post_hitl_late_approval_restore
  | Cmd.Post_mcp_tools_call _
  | Cmd.Post_skill_editor_read _
  | Cmd.Post_skill_editor_preview_new _
  | Cmd.Post_skill_editor_create _
  | Cmd.Post_skill_editor_preview _
  | Cmd.Post_skill_editor_save _
  | Cmd.Post_skills_refresh
  | Cmd.Post_preset_save _
  | Cmd.Post_preset_create _
  | Cmd.Post_preset_restore _
  | Cmd.Post_preset_delete _
  | Cmd.Post_runtime_routing_action _
  | Cmd.Post_runtime_config_raw_preview _
  | Cmd.Post_board_attention_quarantine_recovery _
  | Cmd.Post_lane_addon_operator _
  | Cmd.Post_browser_command _
  | Cmd.Post_browser_interact _ ->
      Rbac.Single_user_token_admin_only

let route_access_of_put_request : Cmd.put_request -> Rbac.route_access =
  function
  | Cmd.Put_wiki_page _ -> Rbac.Bridged_token_admin

let route_access_of_delete_request : Cmd.delete_request -> Rbac.route_access =
  function
  | Cmd.Delete_skill_editor _ -> Rbac.Single_user_token_admin_only

let route_access_of_stream_post_request :
    Cmd.stream_post_request -> Rbac.route_access = function
  | Cmd.Stream_keeper_chat _ -> Rbac.Single_user_write
  | Cmd.Stream_github_login _ -> Rbac.Single_user_token_admin_only

let route_access_of_editor_target : Cmd.editor_target -> Rbac.route_access =
  function
  | Cmd.Edit_runtime_toml | Cmd.Edit_keeper_toml _ ->
      Rbac.Single_user_token_admin_only
  | Cmd.Edit_wiki_page _ -> Rbac.Bridged_token_admin

let route_access_of_stream_id : Subscriptions.stream_id -> Rbac.route_access =
  Subscriptions.route_access_of_stream_id

let route_access_of_workspace : Nav.workspace -> Rbac.route_access = function
  | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Runtime -> Rbac.Workspace_read
  | Nav.Keepers -> Rbac.Single_user_read
  | Nav.Infra -> Rbac.Su_read_ma_admin

let route_access_of_work_tab : Nav.work_tab -> Rbac.route_access = function
  | Nav.Work_pipeline | Nav.Work_tasks | Nav.Work_schedules
  | Nav.Work_candle_scorecard ->
      Rbac.Workspace_read
  | Nav.Work_inbox | Nav.Work_harness -> Rbac.Single_user_read

let route_access_of_knowledge_tab : Nav.knowledge_tab -> Rbac.route_access =
  function
  | Nav.Knowledge_wiki | Nav.Knowledge_memory -> Rbac.Workspace_read
  | Nav.Knowledge_board -> Rbac.Single_user_read
  | Nav.Knowledge_artifacts -> Rbac.Single_user_token_admin_only

let route_access_of_keeper_tab : Nav.keeper_tab -> Rbac.route_access = function
  | Nav.Keeper_chat | Nav.Keeper_trace | Nav.Keeper_memory
  | Nav.Keeper_work_sandbox | Nav.Keeper_identity ->
      Rbac.Single_user_read
  | Nav.Keeper_config -> Rbac.Bridged_token_admin

let route_access_of_runtime_tab : Nav.runtime_tab -> Rbac.route_access =
  function
  | Nav.Runtime_quotas_credits | Nav.Runtime_failover_lanes
  | Nav.Runtime_tools_usage ->
      Rbac.Workspace_read
  | Nav.Runtime_efficiency_spend | Nav.Runtime_fusion | Nav.Runtime_connectors
  | Nav.Runtime_addons_browser ->
      Rbac.Single_user_read

let route_access_of_infra_tab : Nav.infra_tab -> Rbac.route_access = function
  | Nav.Infra_sandboxes | Nav.Infra_activity_logs -> Rbac.Su_read_ma_admin
  | Nav.Infra_repos_changes | Nav.Infra_code -> Rbac.Single_user_read

let route_access_of_inspector : Nav.inspector -> Rbac.route_access = function
  | Nav.Verification_inspector _ | Nav.File_inspector _ -> Rbac.Single_user_read
  | Nav.Tool_inspector _ -> Rbac.Workspace_read
  | Nav.Skill_inspector _ -> Rbac.Single_user_token_admin_only
  | Nav.Exact_run_inspector _ -> Rbac.Bridged_token_admin

let route_access_of_inline_action : Nav.inline_action_kind -> Rbac.route_access
    = function
  | Nav.Code_finder_form | Nav.Code_search_form -> Rbac.Single_user_read
  | Nav.Btw_query
  | Nav.Board_new_post
  | Nav.Board_goal_proposal
  | Nav.Board_comment _
  | Nav.Task_create_form
  | Nav.Task_transition_form _
  | Nav.Goal_upsert_form _
  | Nav.Goal_drop _
  | Nav.Schedule_form
  | Nav.Connector_form
  | Nav.Fusion_launch_form
  | Nav.Addon_attach_form
  | Nav.Addon_detach_confirm _
  | Nav.Addon_invoke_action _
  | Nav.Addon_decl_form _
  | Nav.Addon_act_form _ ->
      Rbac.Single_user_write
  | Nav.Wiki_edit_form -> Rbac.Bridged_token_admin
  | Nav.Setup_login_start_form | Nav.Setup_login_input_form _ ->
      Rbac.Own_provider_manage
  | Nav.Prompt_override_form _ | Nav.Runtime_param_set_form _ ->
      Rbac.Single_user_role_admin
  | Nav.Gate_reject _
  | Nav.Verification_reject _
  | Nav.Harness_overrule _
  | Nav.Task_cancel _
  | Nav.Task_link_goal _
  | Nav.Repo_add_form
  | Nav.Goal_confirmation_proof
  | Nav.Memory_act_form
  | Nav.Runtime_assign_form
  | Nav.Setup_account_key_form
  | Nav.Github_token_form _
  | Nav.Runtime_lane_create
  | Nav.Runtime_lane_edit _
  | Nav.Runtime_lane_delete _
  | Nav.Board_delete_post _
  | Nav.Keeper_lifecycle_form _
  | Nav.Keeper_purge_confirm _
  | Nav.Keeper_control_confirm _
  | Nav.Keeper_clear_form _
  | Nav.Keeper_operator_note_form _
  | Nav.Discord_reply_form _
  | Nav.Tool_execute_form _
  | Nav.Skill_create_form
  | Nav.Skill_edit_form _
  | Nav.Skill_delete_confirm _
  | Nav.Preset_create_form
  | Nav.Default_route_edit
  | Nav.Lane_rename_form _
  | Nav.Browser_interact_form _ ->
      Rbac.Single_user_token_admin_only

let route_access_of_overlay : Nav.overlay -> Rbac.route_access = function
  | Nav.Palette | Nav.Incidents | Nav.Help | Nav.System_gate _ ->
      Rbac.Always_public
  | Nav.Settings _ -> Rbac.Bridged_token_admin
  | Nav.Queue_context _ -> Rbac.Single_user_read
  | Nav.Ask_answer -> Rbac.Single_user_role_admin
  | Nav.Inline_action kind -> route_access_of_inline_action kind

let route_access_of_menu_target : Nav.menu_target -> Rbac.route_access =
  function
  | Nav.Menu_pulse -> Rbac.Workspace_read
  | Nav.Menu_work tab -> route_access_of_work_tab tab
  | Nav.Menu_knowledge tab -> route_access_of_knowledge_tab tab
  | Nav.Menu_keepers -> Rbac.Single_user_read
  | Nav.Menu_keeper_tab tab -> route_access_of_keeper_tab tab
  | Nav.Menu_runtime tab -> route_access_of_runtime_tab tab
  | Nav.Menu_infra tab -> route_access_of_infra_tab tab
  | Nav.Menu_settings -> Rbac.Bridged_token_admin
  | Nav.Menu_incidents | Nav.Menu_help -> Rbac.Always_public
  | Nav.Menu_queue_context -> Rbac.Single_user_read

let route_access_of_slash_command_id : Slash.command_id -> Rbac.route_access =
  function
  | Slash.Cmd_pulse | Slash.Cmd_work | Slash.Cmd_knowledge | Slash.Cmd_runtime
    ->
      Rbac.Workspace_read
  | Slash.Cmd_keepers
  | Slash.Cmd_keeper
  | Slash.Cmd_jump
  | Slash.Cmd_queue
  | Slash.Cmd_context
  | Slash.Cmd_addon ->
      Rbac.Single_user_read
  | Slash.Cmd_btw -> Rbac.Single_user_write
  | Slash.Cmd_infra -> Rbac.Su_read_ma_admin
  | Slash.Cmd_config -> Rbac.Bridged_token_admin
  | Slash.Cmd_prompt -> Rbac.Single_user_role_admin
  | Slash.Cmd_voice
  | Slash.Cmd_model
  | Slash.Cmd_discord_reply
  | Slash.Cmd_wake
  | Slash.Cmd_up
  | Slash.Cmd_resume
  | Slash.Cmd_pause
  | Slash.Cmd_down
  | Slash.Cmd_ctl
  | Slash.Cmd_gate
  | Slash.Cmd_exec
  | Slash.Cmd_skill
  | Slash.Cmd_preset
  | Slash.Cmd_lane
  | Slash.Cmd_browser ->
      Rbac.Single_user_token_admin_only
  | Slash.Cmd_incidents
  | Slash.Cmd_tools
  | Slash.Cmd_clear
  | Slash.Cmd_theme
  | Slash.Cmd_lang
  | Slash.Cmd_help
  | Slash.Cmd_restart
  | Slash.Cmd_quit ->
      Rbac.Always_public

let route_access_of_slash_parsed : Slash.parsed -> Rbac.route_access = function
  | Slash.Pulse -> route_access_of_slash_command_id Slash.Cmd_pulse
  | Slash.Work -> route_access_of_slash_command_id Slash.Cmd_work
  | Slash.Knowledge -> route_access_of_slash_command_id Slash.Cmd_knowledge
  | Slash.Keepers -> route_access_of_slash_command_id Slash.Cmd_keepers
  | Slash.Runtime -> route_access_of_slash_command_id Slash.Cmd_runtime
  | Slash.Infra -> route_access_of_slash_command_id Slash.Cmd_infra
  | Slash.Keeper _ -> route_access_of_slash_command_id Slash.Cmd_keeper
  | Slash.Model _ -> route_access_of_slash_command_id Slash.Cmd_model
  | Slash.Config _ -> route_access_of_slash_command_id Slash.Cmd_config
  | Slash.Incidents -> route_access_of_slash_command_id Slash.Cmd_incidents
  | Slash.Jump -> route_access_of_slash_command_id Slash.Cmd_jump
  | Slash.Voice -> route_access_of_slash_command_id Slash.Cmd_voice
  | Slash.Btw _ -> route_access_of_slash_command_id Slash.Cmd_btw
  | Slash.Discord_reply ->
      route_access_of_slash_command_id Slash.Cmd_discord_reply
  | Slash.Wake _ -> route_access_of_slash_command_id Slash.Cmd_wake
  | Slash.Up _ -> route_access_of_slash_command_id Slash.Cmd_up
  | Slash.Resume _ -> route_access_of_slash_command_id Slash.Cmd_resume
  | Slash.Pause _ -> route_access_of_slash_command_id Slash.Cmd_pause
  | Slash.Down _ -> route_access_of_slash_command_id Slash.Cmd_down
  | Slash.Queue -> route_access_of_slash_command_id Slash.Cmd_queue
  | Slash.Context -> route_access_of_slash_command_id Slash.Cmd_context
  | Slash.Ctl _ -> route_access_of_slash_command_id Slash.Cmd_ctl
  | Slash.Gate (Slash.Gate_keeper_mode_set _) -> Rbac.Single_user_role_admin
  | Slash.Gate
      ( Slash.Gate_mode_set _
      | Slash.Gate_external_mode_set _
      | Slash.Gate_rule_delete _
      | Slash.Gate_approve_always _
      | Slash.Gate_retry _
      | Slash.Gate_ack_uncertain _
      | Slash.Gate_restore_late ) ->
      Rbac.Single_user_token_admin_only
  | Slash.Exec _ -> route_access_of_slash_command_id Slash.Cmd_exec
  | Slash.Skill _ -> route_access_of_slash_command_id Slash.Cmd_skill
  | Slash.Prompt _ -> Rbac.Single_user_role_admin
  | Slash.Preset (Slash.Preset_list | Slash.Preset_show _) -> Rbac.Single_user_read
  | Slash.Preset
      ( Slash.Preset_save _
      | Slash.Preset_create _
      | Slash.Preset_restore _
      | Slash.Preset_delete _ ) ->
      Rbac.Single_user_token_admin_only
  | Slash.Lane (Slash.Lane_run_inspect _) -> Rbac.Bridged_token_admin
  | Slash.Lane
      ( Slash.Lane_create _
      | Slash.Lane_remove _
      | Slash.Lane_rename _
      | Slash.Lane_set _
      | Slash.Lane_exact_append _
      | Slash.Lane_exact_drop _
      | Slash.Lane_exact_move _
      | Slash.Lane_exact_replace _
      | Slash.Lane_quarantines _
      | Slash.Lane_quarantine_recover _
      | Slash.Lane_raw_preview ) ->
      Rbac.Single_user_token_admin_only
  | Slash.Addon
      (Slash.Addon_asks _ | Slash.Addon_slice _ | Slash.Addon_decl_read _) ->
      Rbac.Single_user_read
  | Slash.Addon
      ( Slash.Addon_attach _
      | Slash.Addon_detach _
      | Slash.Addon_observe _
      | Slash.Addon_act _
      | Slash.Addon_evidence _
      | Slash.Addon_decl_new _ ) ->
      Rbac.Single_user_write
  | Slash.Addon (Slash.Addon_retain _ | Slash.Addon_ask_answer _) ->
      Rbac.Single_user_role_admin
  | Slash.Addon (Slash.Addon_operator _) ->
      Rbac.Single_user_token_admin_only
  | Slash.Browser _ -> route_access_of_slash_command_id Slash.Cmd_browser
  | Slash.Tools _ -> route_access_of_slash_command_id Slash.Cmd_tools
  | Slash.Clear -> route_access_of_slash_command_id Slash.Cmd_clear
  | Slash.Theme _ -> route_access_of_slash_command_id Slash.Cmd_theme
  | Slash.Lang _ -> route_access_of_slash_command_id Slash.Cmd_lang
  | Slash.Help -> route_access_of_slash_command_id Slash.Cmd_help
  | Slash.Restart -> route_access_of_slash_command_id Slash.Cmd_restart
  | Slash.Quit -> route_access_of_slash_command_id Slash.Cmd_quit
  | Slash.Music _ | Slash.Score _ -> Rbac.Always_public

let route_access_of_keymap_action : Keymap.action -> Rbac.route_access =
  function
  | Keymap.Switch_workspace _
  | Keymap.Toggle_sidebar
  | Keymap.Sub_tab _
  | Keymap.Cycle_focus_pane _
  | Keymap.Focus_filter
  | Keymap.Dive_selected
  | Keymap.Confirm_selected
  | Keymap.Pop_back_or_close
  | Keymap.Open_incidents
  | Keymap.Open_help
  | Keymap.Open_palette
  | Keymap.Toggle_tool_details
  | Keymap.Toggle_thinking
  | Keymap.Cycle_origin_mode
  | Keymap.Composer_kill_word
  | Keymap.Composer_newline
  | Keymap.Move _
  | Keymap.Toggle_expand
  | Keymap.Refresh
  | Keymap.Copy_selected
  | Keymap.Open_external
  | Keymap.Toggle_zoom
  | Keymap.Cycle_memory_view
  | Keymap.Toggle_memory_sort
  | Keymap.Cycle_signal_or_source
  | Keymap.Cycle_sort_or_speak
  | Keymap.Cycle_time_window
  | Keymap.Cycle_view_mode
  | Keymap.Step_revision _
  | Keymap.Step_context_item _
  | Keymap.Toggle_unreported
  | Keymap.Copy_hash
  | Keymap.Toggle_memory_scope
  | Keymap.Copy_public_url
  | Keymap.Search_prev_match
  | Keymap.Toggle_memory_chart
  | Keymap.Quit_app ->
      Rbac.Always_public
  | Keymap.Open_settings | Keymap.Open_external_editor | Keymap.Probe_sandbox ->
      Rbac.Bridged_token_admin
  | Keymap.Teleport_blocked
  | Keymap.Open_keeper_switcher
  | Keymap.Open_queue_context
  | Keymap.Refresh_browser_tabs ->
      Rbac.Single_user_read
  | Keymap.Focus_composer
  | Keymap.Submit_steer
  | Keymap.Submit_followup
  | Keymap.Create_new
  | Keymap.Context_primary_action
  | Keymap.Board_vote _
  | Keymap.Cycle_hearth_or_overrule
  | Keymap.Launch_fusion
  | Keymap.Interrupt_turn ->
      Rbac.Single_user_write
  | Keymap.Account_login | Keymap.Poll_account_login ->
      Rbac.Own_provider_manage
  | Keymap.Fast_approve_top
  | Keymap.Fast_deny_top
  | Keymap.Ask_select_choice _ ->
      Rbac.Single_user_role_admin
  | Keymap.Voice_ptt_toggle
  | Keymap.Open_model_switcher
  | Keymap.Toggle_artifact_share
  | Keymap.Unbind_connector
  | Keymap.Entity_approve_or_assign
  | Keymap.Entity_reject_or_cancel
  | Keymap.Edit_or_export
  | Keymap.Configure_provider_key
  | Keymap.Dismiss_errors
  | Keymap.Open_memory_recovery
  | Keymap.Delete_selected
  | Keymap.Link_task_goal
  | Keymap.Keeper_wake_or_online
  | Keymap.Keeper_stop_armed ->
      Rbac.Single_user_token_admin_only

let edit_or_export_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Verification_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_token_admin_only
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_wiki -> Rbac.Bridged_token_admin
          | Nav.Knowledge_memory
            when Knowledge_store.equal_memory_subview m.knowledge.memory_subview
                   Knowledge_store.Mem_diff_flow ->
              Rbac.Workspace_read
          | Nav.Knowledge_artifacts | Nav.Knowledge_board | Nav.Knowledge_memory
            ->
              Rbac.Single_user_token_admin_only)
      | Nav.Keepers -> (
          match m.fleet.keeper_dive_tab with
          | Nav.Keeper_work_sandbox | Nav.Keeper_config ->
              Rbac.Bridged_token_admin
          | Nav.Keeper_memory -> Rbac.Single_user_read
          | Nav.Keeper_chat | Nav.Keeper_trace | Nav.Keeper_identity ->
              Rbac.Single_user_token_admin_only)
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_quotas_credits ->
              if Option.is_some (Runtime_store.active_setup_login_id m.runtime)
              then Rbac.Own_provider_manage
              else Rbac.Bridged_token_admin
          | Nav.Runtime_connectors -> Rbac.Bridged_token_admin
          | Nav.Runtime_fusion -> Rbac.Single_user_read
          | Nav.Runtime_addons_browser -> Rbac.Single_user_write
          | Nav.Runtime_tools_usage -> (
              match m.runtime.tools_subview with
              | Runtime_store.Tools_prompts_presets -> (
                  match m.runtime.pp_section with
                  | Runtime_store.Sec_prompts | Runtime_store.Sec_params ->
                      Rbac.Single_user_role_admin
                  | Runtime_store.Sec_presets
                  | Runtime_store.Sec_async_requests ->
                      Rbac.Single_user_token_admin_only)
              | Runtime_store.Tools_usage_calls
              | Runtime_store.Tools_catalog_tree
              | Runtime_store.Tools_keeper_skills
              | Runtime_store.Tools_quality_gate ->
                  Rbac.Single_user_token_admin_only)
          | Nav.Runtime_failover_lanes | Nav.Runtime_efficiency_spend ->
              Rbac.Single_user_token_admin_only)
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_pipeline ->
              if m.nav.pane_index = 1 && Model.work_pipeline_verifs_visible m
              then Rbac.Single_user_token_admin_only
              else Rbac.Single_user_write
          | Nav.Work_candle_scorecard -> Rbac.Bridged_token_admin
          | Nav.Work_tasks
          | Nav.Work_schedules
          | Nav.Work_inbox
          | Nav.Work_harness ->
              Rbac.Single_user_token_admin_only)
      | Nav.Infra -> (
          match m.infra.active_tab with
          | Nav.Infra_sandboxes -> Rbac.Bridged_token_admin
          | Nav.Infra_repos_changes | Nav.Infra_code | Nav.Infra_activity_logs
            ->
              Rbac.Single_user_token_admin_only)
      | Nav.Pulse -> Rbac.Single_user_token_admin_only)

let launch_fusion_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_write
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge
        when Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_memory
             && Knowledge_store.equal_memory_subview m.knowledge.memory_subview
                  Knowledge_store.Mem_diff_flow ->
          Rbac.Workspace_read
      | Nav.Keepers
        when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory ->
          Rbac.Single_user_read
      | Nav.Infra when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code ->
          Rbac.Single_user_read
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
      | Nav.Infra ->
          Rbac.Single_user_write)

let probe_sandbox_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Bridged_token_admin
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge
        when Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
        ->
          Rbac.Single_user_token_admin_only
      | Nav.Infra when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_code ->
          Rbac.Single_user_read
      | Nav.Runtime
        when Nav.equal_runtime_tab m.runtime.active_tab
               Nav.Runtime_addons_browser ->
          Rbac.Single_user_read
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
      | Nav.Infra ->
          Rbac.Bridged_token_admin)

let create_new_access (m : Model.t) : Rbac.route_access =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> Rbac.Bridged_token_admin
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None -> (
      match Model.active_inspector m with
      | Some (Nav.Skill_inspector _) -> Rbac.Single_user_token_admin_only
      | Some
          ( Nav.Verification_inspector _
          | Nav.Tool_inspector _
          | Nav.Exact_run_inspector _
          | Nav.File_inspector _ ) ->
          Rbac.Single_user_write
      | None -> (
          match m.nav.workspace with
          | Nav.Pulse -> Rbac.Single_user_write
          | Nav.Knowledge -> (
              match m.knowledge.active_tab with
              | Nav.Knowledge_artifacts -> Rbac.Single_user_token_admin_only
              | Nav.Knowledge_board | Nav.Knowledge_wiki | Nav.Knowledge_memory
                ->
                  Rbac.Single_user_write)
          | Nav.Work -> (
              match m.work.active_tab with
              | Nav.Work_harness -> Rbac.Single_user_token_admin_only
              | Nav.Work_pipeline
              | Nav.Work_tasks
              | Nav.Work_schedules
              | Nav.Work_inbox
              | Nav.Work_candle_scorecard ->
                  Rbac.Single_user_write)
          | Nav.Runtime -> (
              match m.runtime.active_tab with
              | Nav.Runtime_connectors | Nav.Runtime_addons_browser ->
                  Rbac.Single_user_write
              | Nav.Runtime_quotas_credits
              | Nav.Runtime_failover_lanes
              | Nav.Runtime_tools_usage
              | Nav.Runtime_efficiency_spend
              | Nav.Runtime_fusion ->
                  Rbac.Single_user_token_admin_only)
          | Nav.Infra -> Rbac.Single_user_token_admin_only
          | Nav.Keepers -> Rbac.Bridged_token_admin))

let context_primary_action_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_write
  | None -> (
      match m.nav.workspace with
      | Nav.Knowledge -> (
          match m.knowledge.active_tab with
          | Nav.Knowledge_artifacts -> Rbac.Single_user_token_admin_only
          | Nav.Knowledge_board | Nav.Knowledge_wiki | Nav.Knowledge_memory ->
              Rbac.Single_user_write)
      | Nav.Keepers ->
          let in_board_recovery =
            Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_work_sandbox
            &&
            match Model.selected_keeper_name m with
            | Some name ->
                Board_recovery.shown ~keeper:name m.knowledge.board_recovery
            | None -> false
          in
          if in_board_recovery then Rbac.Single_user_token_admin_only
          else Rbac.Single_user_read
      | Nav.Work -> (
          match m.work.active_tab with
          | Nav.Work_inbox -> Rbac.Single_user_read
          | Nav.Work_pipeline
          | Nav.Work_tasks
          | Nav.Work_schedules
          | Nav.Work_candle_scorecard
          | Nav.Work_harness ->
              Rbac.Single_user_write)
      | Nav.Runtime -> (
          match m.runtime.active_tab with
          | Nav.Runtime_addons_browser ->
              if m.nav.pane_index = 1 then Rbac.Single_user_token_admin_only
              else if Runtime_store.open_lane_addon_asks m.runtime <> [] then
                Rbac.Single_user_role_admin
              else Rbac.Single_user_write
          | Nav.Runtime_quotas_credits
          | Nav.Runtime_failover_lanes
          | Nav.Runtime_tools_usage
          | Nav.Runtime_efficiency_spend
          | Nav.Runtime_fusion
          | Nav.Runtime_connectors ->
              Rbac.Single_user_write)
      | Nav.Pulse | Nav.Infra -> Rbac.Single_user_write)

let entity_approve_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_token_admin_only
  | None -> (
      match m.nav.workspace with
      | Nav.Infra
        when Nav.equal_infra_tab m.infra.active_tab Nav.Infra_activity_logs ->
          Rbac.Su_read_ma_admin
      | Nav.Knowledge
        when Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
        ->
          Rbac.Single_user_write
      | Nav.Work
        when Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
             && not
                  (m.nav.pane_index = 1 && Model.work_pipeline_verifs_visible m)
        ->
          Rbac.Single_user_write
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
      | Nav.Infra ->
          Rbac.Single_user_token_admin_only)

let entity_reject_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_token_admin_only
  | None -> (
      match m.nav.workspace with
      | Nav.Work
        when Nav.equal_work_tab m.work.active_tab Nav.Work_pipeline
             && not
                  (m.nav.pane_index = 1 && Model.work_pipeline_verifs_visible m)
        ->
          Rbac.Single_user_write
      | Nav.Runtime
        when Nav.equal_runtime_tab m.runtime.active_tab
               Nav.Runtime_addons_browser
             && (not m.runtime.addon_catalog_mode)
             && m.nav.pane_index = 0
             && not (Model.is_zoomed_active m) ->
          Rbac.Single_user_write
      | Nav.Runtime
        when Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_tools_usage
             && Runtime_store.equal_tools_subview m.runtime.tools_subview
                  Runtime_store.Tools_prompts_presets -> (
          match m.runtime.pp_section with
          | Runtime_store.Sec_prompts | Runtime_store.Sec_params ->
              Rbac.Single_user_role_admin
          | Runtime_store.Sec_presets | Runtime_store.Sec_async_requests ->
              Rbac.Single_user_token_admin_only)
      | Nav.Pulse | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime
      | Nav.Infra ->
          Rbac.Single_user_token_admin_only)

let open_external_editor_access (m : Model.t) : Rbac.route_access =
  match m.nav.overlay with
  | Some (Nav.Settings _) -> Rbac.Single_user_token_admin_only
  | Some
      ( Nav.Palette
      | Nav.Incidents
      | Nav.Queue_context _
      | Nav.Inline_action _
      | Nav.Ask_answer
      | Nav.Help
      | Nav.System_gate _ )
  | None ->
      Rbac.Bridged_token_admin

let cycle_hearth_or_overrule_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_token_admin_only
  | None ->
      if
        Nav.equal_workspace m.nav.workspace Nav.Knowledge
        && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
      then Rbac.Single_user_read
      else Rbac.Single_user_token_admin_only

let dismiss_errors_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Single_user_token_admin_only
  | None ->
      if
        Nav.equal_workspace m.nav.workspace Nav.Keepers
        && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_chat
      then Rbac.Single_user_read
      else Rbac.Single_user_token_admin_only

let toggle_unreported_access (m : Model.t) : Rbac.route_access =
  match Model.active_inspector m with
  | Some
      ( Nav.Verification_inspector _
      | Nav.Tool_inspector _
      | Nav.Skill_inspector _
      | Nav.Exact_run_inspector _
      | Nav.File_inspector _ ) ->
      Rbac.Always_public
  | None ->
      if
        Nav.equal_workspace m.nav.workspace Nav.Knowledge
        && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
      then Rbac.Single_user_write
      else if
        Nav.equal_workspace m.nav.workspace Nav.Runtime
        && Nav.equal_runtime_tab m.runtime.active_tab
             Nav.Runtime_quotas_credits
      then Rbac.Workspace_read
      else Rbac.Always_public

let account_login_access (m : Model.t) : Rbac.route_access =
  if
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Keepers
    && Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_identity
  then Rbac.Single_user_token_admin_only
  else Rbac.Own_provider_manage

let unbind_connector_access (m : Model.t) : Rbac.route_access =
  if
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Runtime
    && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_connectors
  then Rbac.Single_user_write
  else Rbac.Single_user_token_admin_only

let delete_selected_access (m : Model.t) : Rbac.route_access =
  if Option.is_some m.nav.overlay || Model.sidebar_has_focus m then
    Rbac.Single_user_token_admin_only
  else if
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Runtime
    && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_failover_lanes
  then Rbac.Single_user_token_admin_only
  else if
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Knowledge
    && Nav.equal_knowledge_tab m.knowledge.active_tab Nav.Knowledge_board
  then Rbac.Single_user_token_admin_only
  else if
    Option.is_none (Model.active_inspector m)
    && Nav.equal_workspace m.nav.workspace Nav.Runtime
    && Nav.equal_runtime_tab m.runtime.active_tab Nav.Runtime_addons_browser
    && not m.runtime.addon_catalog_mode
  then Rbac.Single_user_write
  else if Model.is_memory_explorer_surface m then
    if Nav.equal_workspace m.nav.workspace Nav.Keepers then
      Rbac.Single_user_read
    else Rbac.Workspace_read
  else if Model.is_keeper_config_active m then Rbac.Bridged_token_admin
  else Rbac.Single_user_token_admin_only

let route_access_of_keymap_action_in_model (m : Model.t) (act : Keymap.action) :
    Rbac.route_access =
  match act with
  | Keymap.Edit_or_export -> edit_or_export_access m
  | Keymap.Launch_fusion -> launch_fusion_access m
  | Keymap.Probe_sandbox -> probe_sandbox_access m
  | Keymap.Create_new -> create_new_access m
  | Keymap.Context_primary_action -> context_primary_action_access m
  | Keymap.Entity_approve_or_assign -> entity_approve_access m
  | Keymap.Entity_reject_or_cancel -> entity_reject_access m
  | Keymap.Open_external_editor -> open_external_editor_access m
  | Keymap.Cycle_hearth_or_overrule -> cycle_hearth_or_overrule_access m
  | Keymap.Dismiss_errors -> dismiss_errors_access m
  | Keymap.Toggle_unreported -> toggle_unreported_access m
  | Keymap.Account_login -> account_login_access m
  | Keymap.Unbind_connector -> unbind_connector_access m
  | Keymap.Delete_selected -> delete_selected_access m
  | Keymap.Switch_workspace _
  | Keymap.Toggle_sidebar
  | Keymap.Sub_tab _
  | Keymap.Cycle_focus_pane _
  | Keymap.Focus_composer
  | Keymap.Focus_filter
  | Keymap.Dive_selected
  | Keymap.Confirm_selected
  | Keymap.Pop_back_or_close
  | Keymap.Open_settings
  | Keymap.Teleport_blocked
  | Keymap.Open_incidents
  | Keymap.Voice_ptt_toggle
  | Keymap.Fast_approve_top
  | Keymap.Fast_deny_top
  | Keymap.Ask_select_choice _
  | Keymap.Open_help
  | Keymap.Open_palette
  | Keymap.Open_keeper_switcher
  | Keymap.Open_model_switcher
  | Keymap.Toggle_tool_details
  | Keymap.Open_queue_context
  | Keymap.Toggle_thinking
  | Keymap.Cycle_origin_mode
  | Keymap.Composer_kill_word
  | Keymap.Composer_newline
  | Keymap.Submit_steer
  | Keymap.Submit_followup
  | Keymap.Move _
  | Keymap.Toggle_expand
  | Keymap.Refresh
  | Keymap.Copy_selected
  | Keymap.Open_external
  | Keymap.Toggle_zoom
  | Keymap.Cycle_memory_view
  | Keymap.Toggle_memory_sort
  | Keymap.Cycle_signal_or_source
  | Keymap.Cycle_sort_or_speak
  | Keymap.Cycle_time_window
  | Keymap.Cycle_view_mode
  | Keymap.Toggle_artifact_share
  | Keymap.Step_revision _
  | Keymap.Step_context_item _
  | Keymap.Configure_provider_key
  | Keymap.Poll_account_login
  | Keymap.Copy_hash
  | Keymap.Board_vote _
  | Keymap.Toggle_memory_scope
  | Keymap.Copy_public_url
  | Keymap.Refresh_browser_tabs
  | Keymap.Open_memory_recovery
  | Keymap.Search_prev_match
  | Keymap.Toggle_memory_chart
  | Keymap.Interrupt_turn
  | Keymap.Link_task_goal
  | Keymap.Keeper_wake_or_online
  | Keymap.Keeper_stop_armed
  | Keymap.Quit_app ->
      route_access_of_keymap_action act

let can_chat_with_keeper session =
  match session with
  | Rbac.Single_user_local { can_keeper_msg = false; auth_error_detail; _ } ->
      let detail =
        Option.value auth_error_detail
          ~default:"keeper messaging is not authorized for this caller"
      in
      Rbac.Denied (Rbac.Auth_required (Rbac.Forbidden_credential detail))
  | Rbac.Single_user_local { can_keeper_msg = true; _ } ->
      Rbac.decide session Rbac.Single_user_write
  | Rbac.Probing_health
  | Rbac.Probing_single_user _
  | Rbac.Probing_multi_account _
  | Rbac.Single_user_auth_required _
  | Rbac.Multi_account_signed_out _
  | Rbac.Multi_account_signed_in _
  | Rbac.Auth_unavailable _ ->
      Rbac.decide session Rbac.Single_user_write

let decide_keymap_action session act =
  match act with
  | Keymap.Submit_steer | Keymap.Submit_followup -> can_chat_with_keeper session
  | Keymap.Switch_workspace _
  | Keymap.Toggle_sidebar
  | Keymap.Sub_tab _
  | Keymap.Cycle_focus_pane _
  | Keymap.Focus_composer
  | Keymap.Focus_filter
  | Keymap.Dive_selected
  | Keymap.Confirm_selected
  | Keymap.Pop_back_or_close
  | Keymap.Open_settings
  | Keymap.Teleport_blocked
  | Keymap.Open_incidents
  | Keymap.Voice_ptt_toggle
  | Keymap.Fast_approve_top
  | Keymap.Fast_deny_top
  | Keymap.Ask_select_choice _
  | Keymap.Open_help
  | Keymap.Open_palette
  | Keymap.Open_keeper_switcher
  | Keymap.Open_model_switcher
  | Keymap.Toggle_tool_details
  | Keymap.Open_queue_context
  | Keymap.Toggle_thinking
  | Keymap.Cycle_origin_mode
  | Keymap.Composer_kill_word
  | Keymap.Composer_newline
  | Keymap.Move _
  | Keymap.Toggle_expand
  | Keymap.Create_new
  | Keymap.Refresh
  | Keymap.Copy_selected
  | Keymap.Open_external
  | Keymap.Toggle_zoom
  | Keymap.Cycle_memory_view
  | Keymap.Toggle_memory_sort
  | Keymap.Cycle_signal_or_source
  | Keymap.Cycle_sort_or_speak
  | Keymap.Cycle_hearth_or_overrule
  | Keymap.Cycle_time_window
  | Keymap.Cycle_view_mode
  | Keymap.Context_primary_action
  | Keymap.Toggle_artifact_share
  | Keymap.Step_revision _
  | Keymap.Step_context_item _
  | Keymap.Launch_fusion
  | Keymap.Toggle_unreported
  | Keymap.Unbind_connector
  | Keymap.Entity_approve_or_assign
  | Keymap.Entity_reject_or_cancel
  | Keymap.Edit_or_export
  | Keymap.Configure_provider_key
  | Keymap.Account_login
  | Keymap.Poll_account_login
  | Keymap.Copy_hash
  | Keymap.Dismiss_errors
  | Keymap.Board_vote _
  | Keymap.Toggle_memory_scope
  | Keymap.Copy_public_url
  | Keymap.Probe_sandbox
  | Keymap.Refresh_browser_tabs
  | Keymap.Open_memory_recovery
  | Keymap.Search_prev_match
  | Keymap.Toggle_memory_chart
  | Keymap.Open_external_editor
  | Keymap.Interrupt_turn
  | Keymap.Delete_selected
  | Keymap.Link_task_goal
  | Keymap.Keeper_wake_or_online
  | Keymap.Keeper_stop_armed
  | Keymap.Quit_app ->
      Rbac.decide session (route_access_of_keymap_action act)

let can_run_keymap_action session act =
  match decide_keymap_action session act with
  | Rbac.Allowed -> true
  | Rbac.Denied _ -> false

let decide_keymap_action_in_model (m : Model.t) act =
  match act with
  | Keymap.Submit_steer | Keymap.Submit_followup ->
      can_chat_with_keeper m.auth_session
  | Keymap.Switch_workspace _
  | Keymap.Toggle_sidebar
  | Keymap.Sub_tab _
  | Keymap.Cycle_focus_pane _
  | Keymap.Focus_composer
  | Keymap.Focus_filter
  | Keymap.Dive_selected
  | Keymap.Confirm_selected
  | Keymap.Pop_back_or_close
  | Keymap.Open_settings
  | Keymap.Teleport_blocked
  | Keymap.Open_incidents
  | Keymap.Voice_ptt_toggle
  | Keymap.Fast_approve_top
  | Keymap.Fast_deny_top
  | Keymap.Ask_select_choice _
  | Keymap.Open_help
  | Keymap.Open_palette
  | Keymap.Open_keeper_switcher
  | Keymap.Open_model_switcher
  | Keymap.Toggle_tool_details
  | Keymap.Open_queue_context
  | Keymap.Toggle_thinking
  | Keymap.Cycle_origin_mode
  | Keymap.Composer_kill_word
  | Keymap.Composer_newline
  | Keymap.Move _
  | Keymap.Toggle_expand
  | Keymap.Create_new
  | Keymap.Refresh
  | Keymap.Copy_selected
  | Keymap.Open_external
  | Keymap.Toggle_zoom
  | Keymap.Cycle_memory_view
  | Keymap.Toggle_memory_sort
  | Keymap.Cycle_signal_or_source
  | Keymap.Cycle_sort_or_speak
  | Keymap.Cycle_hearth_or_overrule
  | Keymap.Cycle_time_window
  | Keymap.Cycle_view_mode
  | Keymap.Context_primary_action
  | Keymap.Toggle_artifact_share
  | Keymap.Step_revision _
  | Keymap.Step_context_item _
  | Keymap.Launch_fusion
  | Keymap.Toggle_unreported
  | Keymap.Unbind_connector
  | Keymap.Entity_approve_or_assign
  | Keymap.Entity_reject_or_cancel
  | Keymap.Edit_or_export
  | Keymap.Configure_provider_key
  | Keymap.Account_login
  | Keymap.Poll_account_login
  | Keymap.Copy_hash
  | Keymap.Dismiss_errors
  | Keymap.Board_vote _
  | Keymap.Toggle_memory_scope
  | Keymap.Copy_public_url
  | Keymap.Probe_sandbox
  | Keymap.Refresh_browser_tabs
  | Keymap.Open_memory_recovery
  | Keymap.Search_prev_match
  | Keymap.Toggle_memory_chart
  | Keymap.Open_external_editor
  | Keymap.Interrupt_turn
  | Keymap.Delete_selected
  | Keymap.Link_task_goal
  | Keymap.Keeper_wake_or_online
  | Keymap.Keeper_stop_armed
  | Keymap.Quit_app ->
      Rbac.decide m.auth_session (route_access_of_keymap_action_in_model m act)

let can_run_keymap_action_in_model (m : Model.t) act =
  match decide_keymap_action_in_model m act with
  | Rbac.Allowed -> true
  | Rbac.Denied _ -> false

let decide_get session req = Rbac.decide session (route_access_of_get_request req)
let decide_post session req = Rbac.decide session (route_access_of_post_request req)
let decide_put session req = Rbac.decide session (route_access_of_put_request req)
let decide_delete session req =
  Rbac.decide session (route_access_of_delete_request req)
let decide_stream_post session = function
  | Cmd.Stream_keeper_chat _ -> can_chat_with_keeper session
  | Cmd.Stream_github_login _ ->
      Rbac.decide session Rbac.Single_user_token_admin_only
let decide_editor_target session target =
  Rbac.decide session (route_access_of_editor_target target)
let decide_stream session stream =
  Rbac.decide session (route_access_of_stream_id stream)

let decide_workspace session ws =
  Rbac.decide session (route_access_of_workspace ws)
let decide_work_tab session tab =
  Rbac.decide session (route_access_of_work_tab tab)
let decide_knowledge_tab session tab =
  Rbac.decide session (route_access_of_knowledge_tab tab)
let decide_keeper_tab session tab =
  Rbac.decide session (route_access_of_keeper_tab tab)
let decide_runtime_tab session tab =
  Rbac.decide session (route_access_of_runtime_tab tab)
let decide_infra_tab session tab =
  Rbac.decide session (route_access_of_infra_tab tab)
let decide_inspector session insp =
  Rbac.decide session (route_access_of_inspector insp)
let decide_inline_action session kind =
  if Nav.equal_inline_action_kind kind Nav.Btw_query then
    can_chat_with_keeper session
  else Rbac.decide session (route_access_of_inline_action kind)
let decide_overlay session ov =
  match ov with
  | Nav.Inline_action kind -> decide_inline_action session kind
  | Nav.Palette
  | Nav.Settings _
  | Nav.Incidents
  | Nav.Queue_context _
  | Nav.Ask_answer
  | Nav.Help
  | Nav.System_gate _ ->
      Rbac.decide session (route_access_of_overlay ov)
let decide_menu_target session target =
  Rbac.decide session (route_access_of_menu_target target)
let decide_slash_command_id session id =
  match id with
  | Slash.Cmd_btw -> can_chat_with_keeper session
  | Slash.Cmd_pulse
  | Slash.Cmd_work
  | Slash.Cmd_knowledge
  | Slash.Cmd_keepers
  | Slash.Cmd_runtime
  | Slash.Cmd_infra
  | Slash.Cmd_keeper
  | Slash.Cmd_model
  | Slash.Cmd_config
  | Slash.Cmd_incidents
  | Slash.Cmd_jump
  | Slash.Cmd_voice
  | Slash.Cmd_discord_reply
  | Slash.Cmd_wake
  | Slash.Cmd_up
  | Slash.Cmd_resume
  | Slash.Cmd_pause
  | Slash.Cmd_down
  | Slash.Cmd_queue
  | Slash.Cmd_context
  | Slash.Cmd_ctl
  | Slash.Cmd_gate
  | Slash.Cmd_exec
  | Slash.Cmd_skill
  | Slash.Cmd_prompt
  | Slash.Cmd_preset
  | Slash.Cmd_lane
  | Slash.Cmd_addon
  | Slash.Cmd_browser
  | Slash.Cmd_tools
  | Slash.Cmd_clear
  | Slash.Cmd_theme
  | Slash.Cmd_lang
  | Slash.Cmd_help
  | Slash.Cmd_restart
  | Slash.Cmd_quit ->
      Rbac.decide session (route_access_of_slash_command_id id)
let decide_slash_parsed session parsed =
  match parsed with
  | Slash.Btw _ -> can_chat_with_keeper session
  | Slash.Pulse
  | Slash.Work
  | Slash.Knowledge
  | Slash.Keepers
  | Slash.Runtime
  | Slash.Infra
  | Slash.Keeper _
  | Slash.Model _
  | Slash.Config _
  | Slash.Incidents
  | Slash.Jump
  | Slash.Voice
  | Slash.Discord_reply
  | Slash.Wake _
  | Slash.Up _
  | Slash.Resume _
  | Slash.Pause _
  | Slash.Down _
  | Slash.Queue
  | Slash.Context
  | Slash.Ctl _
  | Slash.Gate _
  | Slash.Exec _
  | Slash.Skill _
  | Slash.Prompt _
  | Slash.Preset _
  | Slash.Lane _
  | Slash.Addon _
  | Slash.Browser _
  | Slash.Tools _
  | Slash.Clear
  | Slash.Theme _
  | Slash.Lang _
  | Slash.Help
  | Slash.Restart
  | Slash.Quit
  | Slash.Music _
  | Slash.Score _ ->
      Rbac.decide session (route_access_of_slash_parsed parsed)

let allowed_of = function Rbac.Allowed -> true | Rbac.Denied _ -> false

let can_fetch_get session req = allowed_of (decide_get session req)
let can_post session req = allowed_of (decide_post session req)
let can_put session req = allowed_of (decide_put session req)
let can_delete session req = allowed_of (decide_delete session req)
let can_stream_post session req = allowed_of (decide_stream_post session req)
let can_stream session stream = allowed_of (decide_stream session stream)
let can_access_workspace session ws = allowed_of (decide_workspace session ws)
let can_access_overlay session ov = allowed_of (decide_overlay session ov)
let can_access_inline_action session kind =
  allowed_of (decide_inline_action session kind)
let can_access_menu_target session target =
  allowed_of (decide_menu_target session target)
let can_run_slash_command_id session id =
  allowed_of (decide_slash_command_id session id)

let rec is_cmd_allowed session = function
  | Cmd.Batch cmds -> List.for_all (is_cmd_allowed session) cmds
  | Cmd.Http_get { req; _ } -> can_fetch_get session req
  | Cmd.Http_post { req; _ } -> can_post session req
  | Cmd.Http_put { req; _ } -> can_put session req
  | Cmd.Http_delete { req; _ } -> can_delete session req
  | Cmd.Http_post_stream { req; _ } -> can_stream_post session req
  | Cmd.Open_editor_escape_hatch target ->
      allowed_of (decide_editor_target session target)
  | Cmd.Fetch_artifact_and_copy _ | Cmd.Export_artifact _ ->
      Rbac.is_allowed session Rbac.Single_user_read
  | Cmd.Open_dos_screen _ -> Rbac.is_allowed session Rbac.Machine_play
  | Cmd.Voice_cmd (Cmd.Start_ptt _) ->
      Rbac.is_allowed session Rbac.Single_user_token_admin_only
  | Cmd.Voice_cmd (Cmd.Stop_ptt | Cmd.Cancel_ptt | Cmd.Probe_capabilities) ->
      true
  | Cmd.Sync_streams _
  | Cmd.Update_workspace_guard _
  | Cmd.Copy_clipboard _
  | Cmd.Render_memory_diagram _
  | Cmd.Cancel_memory_diagram
  | Cmd.Open_external_url _
  | Cmd.Open_terminal_program _
  | Cmd.Start_local_server
  | Cmd.Restart_tui
  | Cmd.Quit _ ->
      true

let rec filter_cmd session = function
  | Cmd.Batch cmds -> (
      match filter_cmds session cmds with
      | [] -> None
      | [ single ] -> Some single
      | many -> Some (Cmd.Batch many))
  | Cmd.Sync_streams { epoch; streams } ->
      Some
        (Cmd.Sync_streams
           { epoch; streams = List.filter (can_stream session) streams })
  | ( Cmd.Http_get _
    | Cmd.Http_post _
    | Cmd.Http_put _
    | Cmd.Http_delete _
    | Cmd.Http_post_stream _
    | Cmd.Open_editor_escape_hatch _
    | Cmd.Fetch_artifact_and_copy _
    | Cmd.Export_artifact _
    | Cmd.Open_dos_screen _
    | Cmd.Voice_cmd _
    | Cmd.Update_workspace_guard _
    | Cmd.Copy_clipboard _
    | Cmd.Render_memory_diagram _
    | Cmd.Cancel_memory_diagram
    | Cmd.Open_external_url _
    | Cmd.Open_terminal_program _
    | Cmd.Start_local_server
    | Cmd.Restart_tui
    | Cmd.Quit _ ) as cmd ->
      if is_cmd_allowed session cmd then Some cmd else None

and filter_cmds session cmds = List.filter_map (filter_cmd session) cmds

let active_view_verdict (m : Model.t) =
  let session = m.auth_session in
  match Model.active_inspector m with
  | Some insp -> decide_inspector session insp
  | None -> (
      match decide_workspace session m.nav.workspace with
      | Rbac.Denied _ as denied -> denied
      | Rbac.Allowed -> (
          match m.nav.workspace with
          | Nav.Pulse -> Rbac.Allowed
          | Nav.Work -> decide_work_tab session m.work.active_tab
          | Nav.Knowledge -> decide_knowledge_tab session m.knowledge.active_tab
          | Nav.Keepers -> decide_keeper_tab session m.fleet.keeper_dive_tab
          | Nav.Runtime -> decide_runtime_tab session m.runtime.active_tab
          | Nav.Infra -> decide_infra_tab session m.infra.active_tab))
