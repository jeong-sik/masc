open Masc_tui_core
open Masc_tui_protocol

type get_request =
  | Get_health
  | Get_dashboard_shell
  | Get_keepers_roster
  | Get_keeper_turns
  | Get_keeper_turn_records of { keeper : string; limit : int }
  | Get_chat_history of {
      keeper : string;
      limit : int option;
      cursor : string option;
    }
  | Get_chat_queue of { keeper : string }
  | Get_chat_status of { keeper : string; operation_id : string }
  | Get_chat_operation_events of {
      keeper : string;
      operation_id : string;
      from : Wire_chat_journal.from;
    }
  | Get_planning
  | Get_verifications of {
      view : [ `Pending | `All ];
      limit : int;
      offset : int;
    }
  | Get_schedules of { cursor : string option }
  | Get_asks of { keeper : string option; include_resolved : bool }
  | Get_tool_approvals
  | Get_gate_pending
  | Get_candle_ledger of { limit : int option }
  | Get_board_feed of {
      sort_by : string;
      hearth : string option;
      signal_only : bool;
      limit : int option;
      offset : int option;
    }
  | Get_board_hearths
  | Get_board_thread of { post_id : string; comment_limit : int option }
  | Get_wiki_index of {
      tag : string option;
      source : string option;
      sort : string option;
    }
  | Get_wiki_page of { page : string }
  | Get_wiki_log of { limit : int option; page : string option }
  | Get_wiki_search of { query : string; limit : int option }
  | Get_wiki_lint
  | Get_artifacts
  | Get_artifact_detail of { id : string; revision : int option }
  | Get_artifact_checks
  | Get_world_memory
  | Get_memory_diff of {
      keeper : string option;
      window : Knowledge_store.memory_diff_window;
    }
  | Get_keeper_memory_os_internals of { keeper : string }
  | Get_keeper_memory_facts of { keeper : string }
  | Get_keeper_memory_activity of { keeper : string; limit : int }
  | Get_keeper_memory_health of { keeper : string option }
  | Get_keeper_context_turn_records of {
      keeper : string;
      limit : int option;
      turn_ref : string option;
    }
  | Get_keeper_provider_input of { keeper : string; turn_ref : string }
  | Get_keeper_provider_input_part of {
      keeper : string;
      turn_ref : string;
      index : int;
    }
  | Get_keeper_cache_outcome of { keeper : string; turn_ref : string }
  | Get_keeper_next_request of { keeper : string }
  | Get_keeper_turn_transcript of { keeper : string; turn_ref : string }
  | Get_keeper_tool_stats of { keeper : string; window_hours : int option }
  | Get_keeper_tool_calls of {
      keeper : string;
      limit : int option;
      execution_ids : string list option;
      turn_ref : string option;
    }
  | Get_keeper_tool_result of {
      keeper : string;
      execution_id : string;
      offset : int option;
      max_bytes : int option;
      source_id : string option;
    }
  | Get_provider_usage of { days : int }
  | Get_keeper_costs of { window_minutes : int }
  | Get_efficiency of { month : string option }
  | Get_models_metrics of { window_minutes : int; bucket_minutes : int }
  | Get_runtime_metrics
  | Get_runtime_resolved
  | Get_runtime_config_raw
  | Get_setup_inventory
  | Get_setup_login_status of { login_id : string }
  | Get_runtime_probe of { force : bool }
  | Get_exact_lane_runs of { lane : string option; limit : int option }
  | Get_fusion_runs
  | Get_tool_series of { bucket : [ `Hour | `Day ]; since_hours : int }
  | Get_tool_series_filtered of {
      bucket : [ `Hour | `Day ];
      since_hours : int;
      tool : string option;
    }
  | Get_tools_catalog of { keeper : string option }
  | Get_skills
  | Get_connectors
  | Get_browser_lane
  | Get_lane_addons
  | Get_lane_addon_asks
  | Get_mcp_clients
  | Get_sandboxes
  | Get_keeper_sandbox of { keeper : string }
  | Get_repositories
  | Get_repository_activity of { repo_id : string }
  | Get_system_logs of {
      limit : int option;
      level : Wire_infra.log_level option;
    }
  | Get_tui_preferences
  | Get_config_schema of Wire_config.config_target
  | Get_fusion_run_detail of { run_id : string }
  | Get_fusion_config
  | Get_fusion_board_evidence of { post_id : string }
  | Get_harness_health
  | Get_verification_evidence of { task_id : string; verification_id : string }
  | Get_verification_summary
  | Get_verification_specs
  | Get_verification_tlc_results
  | Get_activity_events of { limit : int option; after_seq : int option }
  | Get_keeper_runtime_trace of { keeper : string; limit : int option }
  | Get_keeper_metrics of { keeper : string }
  | Get_keeper_sandbox_logs of { keeper : string; tail : int option }
  | Get_workspace_children of {
      scope : Wire_infra.workspace_scope;
      dir : string;
    }
  | Get_workspace_files of { scope : Wire_infra.workspace_scope }
  | Get_workspace_search of {
      scope : Wire_infra.workspace_scope;
      query : string;
    }
  | Get_workspace_file of {
      scope : Wire_infra.workspace_scope;
      path : string;
    }
  | Get_git_branches of { scope : Wire_infra.workspace_scope }
  | Get_git_worktrees of { scope : Wire_infra.workspace_scope }
  | Get_git_status of { scope : Wire_infra.workspace_scope }
  | Get_git_blame of { scope : Wire_infra.workspace_scope; path : string }
  | Get_git_log of { scope : Wire_infra.workspace_scope; path : string }
  | Get_git_diff of { scope : Wire_infra.workspace_scope; path : string }
  | Get_workspace_memory_ledger
  | Get_workspace_memory_context
  | Get_keeper_memory_journal of { keeper : string; limit : int option }
  | Get_oauth_providers
  | Get_oauth_attached_tools of { keeper : string }
  | Get_oauth_attempt_status of {
      keeper : string;
      provider : string;
      attempt_id : string;
    }
  | Get_board_quarantines of { keeper : string; generation : int }
  | Get_github_identity of { keeper : string }
  | Get_addon_package_catalog of { directory : string option }
  | Get_addon_package_preview of { manifest_path : string }
  | Get_connector_names of { connector : string; scope : string }
  | Get_keeper_turn_flow of {
      keeper : string;
      trace_id : string;
      turn_id : int;
      turn_ref : string;
    }
  | Get_keeper_checkpoints of { keeper : string }
  | Get_keeper_operator_note of { keeper : string }
  | Get_tool_approval_modes
  | Get_late_approval_attempts
  | Get_tool_quality of { n : int option; window_hours : int option }
  | Get_gate_tool_events of { window_minutes : int option }
  | Get_keeper_waiting_inventory of { keeper : string }

type keeper_turn_interrupt_target =
  [ `Turn_token of string | `Operation_id of string ]

type post_request =
  | Post_ask_answer of {
      keeper : string;
      ask_id : string;
      answers : (string * Wire_work.ask_response) list;
    }
  | Post_tool_approval of {
      keeper : string;
      tool_call_id : string;
      approval_id : string;
      decision : Wire_work.tool_approval_decision;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_gate_resolution of {
      id : string;
      approved : bool;
      reason : string option;
    }
  | Post_goal_transition of {
      goal_id : string;
      action : Wire_work.goal_action;
      note : string option;
      expected_workspace : Wire_work.expected_workspace;
    }
  | Post_goal_confirmation of Wire_work.goal_confirmation_request
  | Post_verification_verdict of {
      task_id : string;
      verification_id : string;
      verdict : Wire_work.operator_verdict;
      notes : string option;
    }
  | Post_memory_act of {
      keeper : string;
      act : Wire_knowledge.memory_recovery_act;
    }
  | Post_fusion_launch of {
      keeper : string;
      request : Wire_runtime.fusion_launch_request;
    }
  | Post_runtime_assignment of {
      keeper_name : string;
      runtime_id : string option;
      source_revision : string option;
      previous_runtime_id : string option;
    }
  | Post_runtime_default_route of { runtime_id : string }
  | Post_runtime_lane_create of {
      lane_id : string;
      kind : Wire_runtime.lane_kind;
      runtime_ids : string list;
    }
  | Post_runtime_lane_update of {
      lane_id : string;
      kind : Wire_runtime.lane_kind;
      runtime_ids : string list;
      expected_source_revision : string option;
    }
  | Post_runtime_lane_delete of {
      lane_id : string;
      expected_source_revision : string option;
    }
  | Post_setup_account_key of {
      integration_id : string;
      key : string;
      source_revision : string;
    }
  | Post_setup_login_start of {
      integration_id : string;
      account_ref : string option;
    }
  | Post_setup_login_input of {
      login_id : string;
      input : Wire_runtime.setup_login_input;
    }
  | Post_sandbox_probe of [ `All | `Keeper of string | `Ssh_pool of string ]
  | Post_config_patch of Wire_config.patch_request
  | Post_tui_preference of Wire_config.tui_preference_change
  | Post_keeper_turn_interrupt of {
      keeper : string;
      target : keeper_turn_interrupt_target;
    }
  | Post_board_create of {
      title : string;
      body : string;
      hearth : string option;
    }
  | Post_board_comment of {
      post_id : string;
      content : string;
      parent_id : string option;
    }
  | Post_board_vote of { post_id : string; direction : [ `Up | `Down ] }
  | Post_board_comment_vote of {
      post_id : string;
      comment_id : string;
      direction : [ `Up | `Down ];
    }
  | Post_artifact_check of {
      expected_workspace : (string * string) option;
      id : string;
      revision : int;
      body_sha256 : string;
      checked : bool;
      expected_change_id : string option;
    }
  | Post_artifact_share of {
      expected_workspace : string * string;
      id : string;
      shared : bool;
      operation_id : string;
      expected_version : int;
      expected_artifact_revision : int;
      expected_artifact_sha256 : string;
    }
  | Post_schedule_create of Wire_work.schedule_create_request
  | Post_connector_bind of {
      connector : string;
      channel_id : string;
      keeper_name : string;
    }
  | Post_connector_unbind of {
      connector : string;
      channel_id : string;
      keeper_name : string option;
    }
  | Post_repo_add of { url : string; branch : string option }
  | Post_task_cancel of {
      task_id : string;
      reason : string option;
      expected_workspace : Wire_work.expected_workspace;
    }
  | Post_harness_overrule of {
      notes_hash : string;
      verdict : [ `Approve | `Reject ];
      reason : string;
    }
  | Post_browser_tabs of { client_id : string }
  | Post_oauth_login of { keeper : string; provider : string }
  | Post_oauth_identity_refresh of { keeper : string; provider : string }
  | Post_oauth_identity_switch of {
      keeper : string;
      provider : string;
      enabled : bool;
    }
  | Post_oauth_disconnect of { keeper : string; provider : string }
  | Post_board_recovery of Board_quarantine.inventory_item
  | Post_github_token of {
      keeper : string;
      token : string;
      hostname : string option;
    }
  | Post_task_create of {
      title : string;
      priority : int;
      description : string option;
      goal_id : string option;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_task_transition of {
      task_id : string;
      action : Wire_work.task_transition_action;
      notes : string option;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_task_link_goal of {
      task_id : string;
      goal_id : string;
      expected_workspace : Wire_work.expected_workspace;
    }
  | Post_goal_upsert of {
      id : string option;
      title : string;
      measure : Wire_work.goal_measure option;
      procedure : string;
      priority : int option;
      due_date : string option;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_board_pin of {
      post_id : string;
      pinned : bool;
    }
  | Post_board_delete of { post_id : string }
  | Post_keeper_lifecycle of {
      keeper : string;
      op : Wire_fleet.keeper_lifecycle_op;
      expected_workspace : (string * string) option;
      from_modal : bool;
    }
  | Post_keeper_purge of {
      keeper : string;
      expected_workspace : string * string;
    }
  | Post_lane_addon_attach of {
      manifest_path : string;
      run_id : string;
      binding : Yojson.Safe.t;
    }
  | Post_lane_addon_detach of { instance_id : string }
  | Post_lane_addon_action of {
      instance_id : string;
      expected_incarnation : string;
      request_id : string;
      action : Yojson.Safe.t;
    }
  | Post_lane_addon_ask_answer of {
      declaration_id : string;
      ask_id : string;
      answers : (string * Wire_work.ask_response) list;
    }
  | Post_keeper_control_lifecycle of {
      keeper : string;
      action : [ `Boot | `Up | `Shutdown | `Reset ];
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_keeper_clear of {
      keeper : string;
      reason : string;
      preserve_system_prompt : bool;
    }
  | Post_keeper_directive of {
      keeper : string;
      directive : Wire_keeper_context.keeper_directive;
      expected_workspace : Wire_work.expected_workspace;
    }
  | Post_keeper_checkpoints of {
      keeper : string;
      action : [ `Preview_purge | `Apply_purge | `Delete_history of string list ];
    }
  | Post_keeper_operator_note of { keeper : string; text : string }
  | Post_keeper_run_next of {
      keeper : string;
      request_id : string;
      interrupt_token : string option;
    }
  | Post_gate_resolution_policy of {
      id : string;
      approved : bool;
      reason : string option;
      remember_rule : bool;
      rule_expires_at : float option;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_gate_mode of { external_lane : bool; mode : Wire_work.gate_mode }
  | Post_gate_rule_delete of { id : string }
  | Post_gate_retry of {
      meta : Wire_work.gate_retry_meta;
      expected_workspace : Wire_work.expected_workspace option;
    }
  | Post_keeper_tool_approval_mode of {
      keeper : string;
      mode : Wire_work.keeper_tool_approval_mode;
    }
  | Post_hitl_ack_uncertain of { keeper : string; consume_id : string }
  | Post_hitl_late_approval_restore
  | Post_mcp_tools_list of { rpc_id : int }
  | Post_mcp_tools_call of {
      rpc_id : int;
      tool_name : string;
      arguments : Yojson.Safe.t;
    }

type put_request =
  | Put_wiki_page of { page : string; request : Wire_knowledge.wiki_put_request }

type stream_post_request =
  | Stream_keeper_chat of {
      request : Wire_fleet.chat_submit_request;
      is_btw : bool;
    }
  | Stream_github_login of { keeper : string }

type voice_cmd =
  | Start_ptt of { device : string option }
  | Stop_ptt
  | Cancel_ptt
  | Probe_capabilities

type editor_target =
  | Edit_runtime_toml
  | Edit_keeper_toml of string
  | Edit_wiki_page of string

type t =
  | Batch of t list
  | Http_get of { epoch : Epoch.t; req : get_request }
  | Http_post of { epoch : Epoch.t; req : post_request }
  | Http_put of { epoch : Epoch.t; req : put_request }
  | Http_post_stream of { epoch : Epoch.t; req : stream_post_request }
  | Sync_streams of { epoch : Epoch.t; streams : Subscriptions.stream_id list }
  | Update_workspace_guard of {
      instance_id : string option;
      workspace_sha256 : string option;
    }
  | Voice_cmd of voice_cmd
  | Copy_clipboard of string
  | Render_memory_diagram of {
      epoch : Epoch.t;
      request_id : int;
      keeper : string;
      event_identity : string;
      kind : Knowledge_store.memory_diagram_kind;
      mode : Knowledge_store.memory_diagram_mode;
      theme_preset : Masc_tui_core.Theme.preset;
      ko : bool;
      tz_offset_sec : int;
      now_unix : float;
      max_width : int;
      chart : Masc_tui_ui.Memory_lineage.diagram;
    }
  | Cancel_memory_diagram
  | Fetch_artifact_and_copy of {
      epoch : Epoch.t;
      id : string;
      revision : int option;
    }
  | Export_artifact of {
      epoch : Epoch.t;
      id : string;
      revision : int option;
      filename_stem : string;
      ext : string;
      content_opt : string option;
      open_after : bool;
    }
  | Open_dos_screen of { epoch : Epoch.t }
  | Open_external_url of string
  | Open_editor_escape_hatch of editor_target
  | Start_local_server
  | Restart_tui
  | Quit of Exit_reason.t

let get_request_path = function
  | Get_health -> Wire_common.health_path
  | Get_dashboard_shell -> Wire_fleet.dashboard_shell_path
  | Get_keepers_roster -> Wire_fleet.dashboard_keepers_path
  | Get_keeper_turns -> Wire_fleet.keepers_turns_path
  | Get_keeper_turn_records { keeper; limit } ->
      Wire_fleet.keeper_turn_records_path ~keeper ~limit
  | Get_chat_queue { keeper } -> Wire_fleet.chat_queue_path ~keeper ~after:None
  | Get_chat_status { keeper; operation_id } -> Wire_fleet.chat_operation_path ~keeper ~operation_id
  | Get_chat_history { keeper; limit; cursor } ->
      Wire_fleet.keeper_chat_history_page_path ~keeper ?limit ?cursor ()
  | Get_chat_operation_events { keeper; operation_id; from } ->
      Wire_chat_journal.path ~keeper ~operation_id ~from
  | Get_planning -> Wire_work.planning_path
  | Get_verifications { view; limit; offset } ->
      let view_str = match view with `Pending -> "awaiting" | `All -> "all" in
      Wire_work.verification_requests_path ~view:view_str ~limit ~offset
  | Get_schedules { cursor } -> Wire_work.schedules_path ?cursor ()
  | Get_asks { keeper; include_resolved } ->
      Wire_work.keeper_asks_path ?keeper ~include_resolved ()
  | Get_tool_approvals -> Wire_work.keeper_tool_approvals_path
  | Get_gate_pending -> Wire_work.gate_path
  | Get_candle_ledger { limit } -> Wire_work.candle_ledger_path ?limit ()
  | Get_board_feed { sort_by; hearth; signal_only; limit; offset } ->
      Wire_knowledge.board_list_path ~sort_by ?hearth ~signal_only ?limit
        ?offset ()
  | Get_board_hearths -> Wire_knowledge.board_hearths_path
  | Get_board_thread { post_id; comment_limit } ->
      Wire_knowledge.board_post_path ~post_id ?comment_limit ()
  | Get_wiki_index { tag; source; sort } ->
      Wire_knowledge.wiki_index_path ?tag ?source ?sort ()
  | Get_wiki_page { page } -> Wire_knowledge.wiki_page_path ~page
  | Get_wiki_log { limit; page } ->
      Wire_knowledge.wiki_log_path ?limit ?page ()
  | Get_wiki_search { query; limit } ->
      Wire_knowledge.wiki_search_path ~query ?limit ()
  | Get_wiki_lint -> Wire_knowledge.wiki_lint_path
  | Get_artifacts -> Wire_knowledge.published_artifacts_path
  | Get_artifact_detail { id; revision } ->
      Wire_knowledge.published_artifact_detail_path ~id ?revision ()
  | Get_artifact_checks -> Wire_knowledge.published_artifact_checks_path
  | Get_world_memory -> Wire_knowledge.world_memory_path
  | Get_memory_diff { keeper; window } -> (
      match window with
      | Knowledge_store.Window_revs { from_rev; to_rev } ->
          Wire_knowledge.memory_diff_path ~keeper ~from_rev ~to_rev ()
      | Knowledge_store.Window_24h
      | Knowledge_store.Window_7d
      | Knowledge_store.Window_30d ->
          let window = Knowledge_store.memory_diff_window_query window in
          Wire_knowledge.memory_diff_path ~keeper ?window ())
  | Get_keeper_memory_os_internals { keeper } ->
      Wire_knowledge.keeper_memory_os_internals_path ~keeper
  | Get_keeper_memory_facts { keeper } ->
      Wire_knowledge.keeper_memory_facts_path ~keeper
  | Get_keeper_memory_activity { keeper; limit } ->
      Wire_knowledge.keeper_memory_activity_path ~keeper ~limit ()
  | Get_keeper_memory_health { keeper } ->
      Wire_knowledge.keeper_memory_health_path ?keeper ()
  | Get_keeper_context_turn_records { keeper; limit; turn_ref } ->
      Wire_keeper_context.keeper_turn_records_path ~keeper ?limit ?turn_ref ()
  | Get_keeper_provider_input { keeper; turn_ref } ->
      Wire_keeper_context.keeper_provider_input_path ~keeper ~turn_ref
  | Get_keeper_provider_input_part { keeper; turn_ref; index } ->
      Wire_keeper_context.keeper_provider_input_part_path ~keeper ~turn_ref
        ~index
  | Get_keeper_cache_outcome { keeper; turn_ref } ->
      Wire_keeper_context.keeper_cache_outcome_path ~keeper ~turn_ref
  | Get_keeper_next_request { keeper } ->
      Wire_keeper_context.keeper_next_request_path ~keeper
  | Get_keeper_turn_transcript { keeper; turn_ref } ->
      Wire_keeper_context.keeper_turn_transcript_path ~keeper ~turn_ref
  | Get_keeper_tool_stats { keeper; window_hours } ->
      Wire_keeper_context.keeper_tool_stats_path ~keeper ?window_hours ()
  | Get_keeper_tool_calls { keeper; limit; execution_ids; turn_ref = _ } ->
      Wire_keeper_context.keeper_tool_calls_path ~keeper ?limit ?execution_ids ()
  | Get_keeper_tool_result { keeper; execution_id; offset; max_bytes; source_id } ->
      Wire_keeper_context.keeper_tool_result_path ~keeper ~execution_id ?offset
        ?max_bytes ?source_id ()
  | Get_provider_usage { days } ->
      Wire_runtime.provider_usage_history_path ~days
  | Get_keeper_costs { window_minutes } ->
      Wire_runtime.keeper_costs_path ~window_minutes
  | Get_efficiency { month } -> Wire_runtime.keeper_efficiency_path ?month ()
  | Get_models_metrics { window_minutes; bucket_minutes } ->
      Wire_runtime.models_metrics_path ~window_minutes ~bucket_minutes
  | Get_runtime_metrics -> Wire_runtime.runtime_metrics_path
  | Get_runtime_resolved -> Wire_runtime.runtime_resolved_path
  | Get_runtime_config_raw -> Wire_runtime.runtime_config_raw_path
  | Get_setup_inventory -> Wire_runtime.setup_inventory_path
  | Get_setup_login_status { login_id } ->
      Wire_runtime.setup_accounts_login_status_path ~login_id
  | Get_runtime_probe { force } -> Wire_runtime.runtime_probe_path ~force ()
  | Get_exact_lane_runs { lane; limit } ->
      Wire_runtime.exact_lane_runs_path ?lane ?limit ()
  | Get_fusion_runs -> Wire_runtime.fusion_runs_path
  | Get_tool_series { bucket; since_hours } ->
      Wire_runtime.tool_series_path ~bucket ~since_hours
  | Get_tool_series_filtered { bucket; since_hours; tool } ->
      Wire_runtime.tool_series_filtered_path ~bucket ~since_hours ?tool ()
  | Get_tools_catalog { keeper } -> Wire_runtime.dashboard_tools_path ?keeper ()
  | Get_skills -> Wire_runtime.skills_path
  | Get_connectors -> Wire_runtime.connectors_path
  | Get_browser_lane -> Wire_runtime.browser_lane_path
  | Get_lane_addons -> Wire_runtime.lane_addons_path
  | Get_lane_addon_asks -> Wire_runtime.lane_addon_asks_path ()
  | Get_mcp_clients -> Wire_runtime.mcp_clients_path
  | Get_sandboxes -> Wire_infra.infra_sandboxes_path
  | Get_keeper_sandbox { keeper } ->
      Wire_infra.infra_sandbox_keeper_path ~keeper
  | Get_repositories -> Wire_infra.repositories_path
  | Get_repository_activity { repo_id } ->
      Wire_infra.repository_activity_path ~repo_id
  | Get_system_logs { limit; level } ->
      let level = Option.map Wire_infra.log_level_to_string level in
      Wire_infra.system_logs_path ?limit ?level ()
  | Get_tui_preferences -> Wire_config.tui_preferences_path
  | Get_config_schema target -> Wire_config.config_schema_path target
  | Get_fusion_run_detail { run_id } ->
      Wire_runtime.fusion_run_detail_path ~run_id
  | Get_fusion_config -> Wire_runtime.fusion_config_path
  | Get_fusion_board_evidence { post_id } ->
      Wire_runtime.fusion_board_post_path ~post_id
  | Get_harness_health -> Wire_work.harness_health_path
  | Get_verification_evidence { task_id; verification_id } ->
      Wire_work.verification_evidence_path ~task_id ~verification_id
  | Get_verification_summary -> Wire_work.verification_summary_path
  | Get_verification_specs -> Wire_work.verification_specs_path
  | Get_verification_tlc_results -> Wire_work.verification_tlc_results_path
  | Get_activity_events { limit; after_seq } ->
      Wire_infra.activity_events_path ?limit ?after_seq ()
  | Get_keeper_runtime_trace { keeper; limit } ->
      Wire_infra.keeper_runtime_trace_path ~keeper ?limit ()
  | Get_keeper_metrics { keeper } -> Wire_keeper_context.keeper_metrics_path ~keeper
  | Get_keeper_sandbox_logs { keeper; tail } ->
      Wire_keeper_context.keeper_sandbox_logs_path ~keeper ?tail ()
  | Get_workspace_children { scope; dir } ->
      Wire_infra.workspace_children_path ~scope ~path:dir ()
  | Get_workspace_files { scope } -> Wire_infra.workspace_files_path ~scope ()
  | Get_workspace_search { scope; query } ->
      Wire_infra.workspace_search_path ~scope ~query ()
  | Get_workspace_file { scope; path } ->
      Wire_infra.workspace_file_path ~scope ~path ()
  | Get_git_branches { scope } -> Wire_infra.git_branches_path ~scope ()
  | Get_git_worktrees { scope } -> Wire_infra.git_worktrees_path ~scope ()
  | Get_git_status { scope } -> Wire_infra.git_status_path ~scope ()
  | Get_git_blame { scope; path } -> Wire_infra.git_blame_path ~scope ~path ()
  | Get_git_log { scope; path } -> Wire_infra.git_log_path ~scope ~path ()
  | Get_git_diff { scope; path } -> Wire_infra.git_diff_path ~scope ~path ()
  | Get_workspace_memory_ledger -> Wire_knowledge.workspace_memory_ledger_path
  | Get_workspace_memory_context -> Wire_knowledge.workspace_memory_context_path
  | Get_keeper_memory_journal { keeper; limit } ->
      Wire_knowledge.keeper_memory_journal_path ~keeper ?limit ~activity:true ()
  | Get_oauth_providers -> Wire_keeper_context.oauth_providers_path
  | Get_oauth_attached_tools { keeper } ->
      Wire_keeper_context.oauth_attached_tools_path ~keeper
  | Get_oauth_attempt_status { keeper; provider; attempt_id } ->
      Wire_keeper_context.oauth_attempt_status_path ~keeper ~provider ~attempt_id
  | Get_board_quarantines { keeper; _ } ->
      Wire_knowledge.board_quarantines_path ~keeper
  | Get_github_identity { keeper } ->
      Wire_keeper_context.github_identity_path ~keeper
  | Get_addon_package_catalog { directory } ->
      Wire_runtime.lane_addon_package_catalog_path ?directory ()
  | Get_addon_package_preview { manifest_path } ->
      Wire_runtime.lane_addon_package_preview_path ~manifest_path
  | Get_connector_names { connector; scope } ->
      Wire_runtime.connector_names_path ~connector ~scope ()
  | Get_keeper_turn_flow { keeper; trace_id; turn_id; turn_ref = _ } ->
      Wire_keeper_context.keeper_turn_flow_path ~keeper ~trace_id ~turn_id ()
  | Get_keeper_checkpoints { keeper } ->
      Wire_keeper_context.keeper_checkpoints_path ~keeper
  | Get_keeper_operator_note { keeper } ->
      Wire_keeper_context.keeper_operator_note_path ~keeper
  | Get_tool_approval_modes -> Wire_work.keeper_tool_approval_mode_path
  | Get_late_approval_attempts -> Wire_work.hitl_late_approval_attempts_path
  | Get_tool_quality { n; window_hours } ->
      Wire_runtime.tool_quality_path ?n ?window_hours ()
  | Get_gate_tool_events { window_minutes } ->
      Wire_work.gate_tool_events_path ?window_minutes ()
  | Get_keeper_waiting_inventory { keeper } ->
      Wire_runtime.keeper_waiting_inventory_path ~keeper

let post_request_path = function
  | Post_ask_answer _ -> Wire_work.keeper_ask_answer_path
  | Post_tool_approval _ -> Wire_work.keeper_tool_approval_path
  | Post_gate_resolution _ -> "/api/v1/dashboard/gate/resolve"
  | Post_goal_transition _ -> "/api/v1/tools/masc_goal_transition"
  | Post_goal_confirmation _ -> Wire_work.goal_confirmation_path
  | Post_verification_verdict _ -> Wire_work.verification_verdict_path
  | Post_memory_act { keeper; _ } ->
      Wire_knowledge.keeper_memory_act_path ~keeper
  | Post_fusion_launch { keeper; _ } -> Wire_runtime.fusion_launch_path ~keeper
  | Post_runtime_assignment _ -> Wire_runtime.runtime_assignment_path
  | Post_runtime_default_route _
  | Post_runtime_lane_create _
  | Post_runtime_lane_update _
  | Post_runtime_lane_delete _ ->
      Wire_runtime.runtime_routing_path
  | Post_setup_account_key _ -> Wire_runtime.setup_credential_path
  | Post_setup_login_start _ -> Wire_runtime.setup_accounts_login_path
  | Post_setup_login_input { login_id; _ } ->
      Wire_runtime.setup_accounts_login_input_path ~login_id
  | Post_sandbox_probe _ -> Wire_infra.infra_sandboxes_probe_path
  | Post_config_patch _ -> Wire_config.config_patch_path
  | Post_tui_preference _ -> Wire_config.tui_preferences_path
  | Post_keeper_turn_interrupt _ -> Wire_fleet.keeper_turn_interrupt_path
  | Post_board_create _ -> "/api/v1/tools/masc_board_post"
  | Post_board_comment _ -> Wire_knowledge.board_comment_path
  | Post_board_vote _ -> Wire_knowledge.board_vote_path
  | Post_board_comment_vote _ -> Wire_knowledge.board_comment_vote_path
  | Post_artifact_check _ -> Wire_knowledge.published_artifact_checks_path
  | Post_artifact_share _ -> Wire_knowledge.published_artifact_shares_path
  | Post_schedule_create _ -> "/api/v1/tools/masc_schedule_create"
  | Post_connector_bind { connector; _ } ->
      Wire_runtime.connector_bind_path ~connector
  | Post_connector_unbind { connector; _ } ->
      Wire_runtime.connector_unbind_path ~connector
  | Post_repo_add _ -> Wire_infra.repositories_path
  | Post_task_cancel _ -> "/api/v1/dashboard/tasks/cancel"
  | Post_harness_overrule _ -> "/api/v1/dashboard/harness-label"
  | Post_browser_tabs _ -> Wire_runtime.browser_lane_read_path
  | Post_oauth_login { keeper; _ } -> Wire_keeper_context.oauth_login_path ~keeper
  | Post_oauth_identity_refresh { keeper; _ } ->
      Wire_keeper_context.oauth_identity_refresh_path ~keeper
  | Post_oauth_identity_switch { keeper; _ } ->
      Wire_keeper_context.oauth_identity_switch_path ~keeper
  | Post_oauth_disconnect _ -> Wire_keeper_context.oauth_disconnect_path
  | Post_board_recovery item ->
      Wire_knowledge.board_quarantines_path ~keeper:item.keeper_name ^ "/" ^
      Wire_common.percent_encode item.partition_id ^ "/recovery"
  | Post_github_token { keeper; _ } ->
      Wire_keeper_context.github_token_path ~keeper
  | Post_task_create _
  | Post_task_transition _
  | Post_goal_upsert _ ->
      Wire_work.mcp_path
  | Post_task_link_goal { task_id; _ } ->
      Wire_work.task_link_goal_path ~task_id
  | Post_board_pin _ -> Wire_knowledge.board_pin_path
  | Post_board_delete _ -> Wire_knowledge.board_delete_path
  | Post_keeper_lifecycle { keeper; op; _ } ->
      Wire_fleet.keeper_lifecycle_path ~keeper op
  | Post_keeper_purge _ -> Wire_fleet.keeper_purge_path
  | Post_lane_addon_attach _ -> Wire_runtime.lane_addon_attach_path
  | Post_lane_addon_detach _ -> Wire_runtime.lane_addon_detach_path
  | Post_lane_addon_action _ -> Wire_runtime.lane_addon_actions_path
  | Post_lane_addon_ask_answer _ -> Wire_runtime.lane_addon_ask_answer_path
  | Post_keeper_control_lifecycle { keeper; action; _ } -> (
      match action with
      | `Boot -> Wire_keeper_context.keeper_boot_path ~keeper
      | `Up -> Wire_keeper_context.keeper_up_path ~keeper
      | `Shutdown -> Wire_keeper_context.keeper_shutdown_path ~keeper
      | `Reset -> Wire_keeper_context.keeper_reset_path ~keeper)
  | Post_keeper_clear { keeper; _ } ->
      Wire_keeper_context.keeper_clear_path ~keeper
  | Post_keeper_directive { keeper; _ } ->
      Wire_keeper_context.keeper_directive_path ~keeper
  | Post_keeper_checkpoints { keeper; _ } ->
      Wire_keeper_context.keeper_checkpoints_path ~keeper
  | Post_keeper_operator_note { keeper; _ } ->
      Wire_keeper_context.keeper_operator_note_path ~keeper
  | Post_keeper_run_next _ -> Wire_keeper_context.keeper_run_next_path
  | Post_gate_resolution_policy _ -> Wire_work.gate_resolve_path
  | Post_gate_mode { external_lane = false; _ } -> Wire_work.gate_mode_path
  | Post_gate_mode { external_lane = true; _ } ->
      Wire_work.gate_external_mode_path
  | Post_gate_rule_delete _ -> Wire_work.gate_rules_delete_path
  | Post_gate_retry _ -> Wire_work.gate_retry_path
  | Post_keeper_tool_approval_mode _ -> Wire_work.keeper_tool_approval_mode_path
  | Post_hitl_ack_uncertain { consume_id; _ } ->
      Wire_work.hitl_approval_recover_path ~approval_id:consume_id
  | Post_hitl_late_approval_restore -> Wire_work.hitl_late_approval_restore_path
  | Post_mcp_tools_list _ | Post_mcp_tools_call _ -> Wire_runtime.mcp_rpc_path

let mcp_tool_name_of_post_request = function
  | Post_task_create _ -> Some "masc_add_task"
  | Post_task_transition _ -> Some "masc_transition"
  | Post_goal_upsert _ -> Some "masc_goal_upsert"
  | Post_ask_answer _
  | Post_tool_approval _
  | Post_gate_resolution _
  | Post_goal_transition _
  | Post_goal_confirmation _
  | Post_verification_verdict _
  | Post_memory_act _
  | Post_fusion_launch _
  | Post_runtime_assignment _
  | Post_runtime_default_route _
  | Post_runtime_lane_create _
  | Post_runtime_lane_update _
  | Post_runtime_lane_delete _
  | Post_setup_account_key _
  | Post_setup_login_start _
  | Post_setup_login_input _
  | Post_sandbox_probe _
  | Post_config_patch _
  | Post_tui_preference _
  | Post_keeper_turn_interrupt _
  | Post_board_create _
  | Post_board_comment _
  | Post_board_vote _
  | Post_board_comment_vote _
  | Post_artifact_check _
  | Post_artifact_share _
  | Post_schedule_create _
  | Post_connector_bind _
  | Post_connector_unbind _
  | Post_repo_add _
  | Post_task_cancel _
  | Post_harness_overrule _
  | Post_browser_tabs _
  | Post_oauth_login _
  | Post_oauth_identity_refresh _
  | Post_oauth_identity_switch _
  | Post_oauth_disconnect _
  | Post_board_recovery _
  | Post_github_token _
  | Post_task_link_goal _
  | Post_board_pin _
  | Post_board_delete _
  | Post_keeper_lifecycle _
  | Post_keeper_purge _
  | Post_lane_addon_attach _
  | Post_lane_addon_detach _
  | Post_lane_addon_action _
  | Post_keeper_control_lifecycle _
  | Post_keeper_clear _
  | Post_keeper_directive _
  | Post_keeper_checkpoints _
  | Post_keeper_operator_note _
  | Post_keeper_run_next _
  | Post_lane_addon_ask_answer _ ->
      None

let post_request_body = function
  | Post_ask_answer { keeper; ask_id; answers } ->
      Wire_work.encode_ask_answer ~keeper ~ask_id ~answers ()
  | Post_tool_approval
      { keeper; tool_call_id; approval_id; decision; expected_workspace } ->
      Wire_work.encode_tool_approval_decision ~keeper ~tool_call_id ~approval_id
        ~decision ?expected_workspace ()
  | Post_gate_resolution { id; approved; reason } ->
      Wire_work.encode_gate_resolution ~id ~approved ~reason
  | Post_goal_transition { goal_id; action; note; expected_workspace } ->
      Wire_work.encode_goal_transition ~goal_id ~action ~note
        ~expected_workspace
  | Post_goal_confirmation req -> Wire_work.encode_goal_confirmation req
  | Post_verification_verdict { task_id; verification_id; verdict; notes } ->
      Wire_work.encode_verification_verdict ~task_id ~verification_id ~verdict
        ~notes
  | Post_memory_act { act; _ } -> Wire_knowledge.encode_memory_act_request act
  | Post_fusion_launch { request; _ } -> Wire_runtime.encode_fusion_launch request
  | Post_runtime_assignment
      { keeper_name; runtime_id; source_revision; previous_runtime_id } ->
      Wire_runtime.encode_runtime_assignment ~keeper_name ~runtime_id
        ~source_revision ~previous_runtime_id ()
  | Post_runtime_default_route { runtime_id } ->
      Wire_runtime.encode_runtime_default_route ~runtime_id
  | Post_runtime_lane_create { lane_id; kind; runtime_ids } ->
      Wire_runtime.encode_runtime_lane_create ~lane_id ~kind ~runtime_ids
  | Post_runtime_lane_update
      { lane_id; kind; runtime_ids; expected_source_revision } ->
      Wire_runtime.encode_runtime_lane_update ~lane_id ~kind ~runtime_ids
        ?expected_source_revision ()
  | Post_runtime_lane_delete { lane_id; expected_source_revision } ->
      Wire_runtime.encode_runtime_lane_delete ~lane_id
        ?expected_source_revision ()
  | Post_setup_account_key { integration_id; key; source_revision } ->
      Wire_runtime.encode_setup_credential ~provider_id:integration_id
        ~secret:key ~source_revision
  | Post_setup_login_start { integration_id; account_ref } ->
      Wire_runtime.encode_setup_account_login_start ~integration_id ?account_ref
        ()
  | Post_setup_login_input { login_id = _; input } ->
      Wire_runtime.encode_setup_login_input input
  | Post_sandbox_probe target -> Wire_infra.encode_sandbox_probe_request target
  | Post_config_patch req -> Wire_config.encode_patch_request req
  | Post_tui_preference change ->
      Wire_config.encode_tui_preference_change change
  | Post_keeper_turn_interrupt { keeper; target } ->
      let target_field =
        match target with
        | `Turn_token tok -> ("interrupt_token", `String tok)
        | `Operation_id op -> ("request_id", `String op)
      in
      `Assoc [ ("name", `String keeper); target_field ]
  | Post_board_create { title; body; hearth } ->
      let base = [ ("title", `String title); ("body", `String body) ] in
      let fields =
        match hearth with
        | Some h when not (String.equal (String.trim h) "") ->
            base @ [ ("hearth", `String (String.trim h)) ]
        | Some _ | None -> base
      in
      `Assoc fields
  | Post_board_comment { post_id; content; parent_id } ->
      Wire_knowledge.encode_board_comment ~post_id ~content ?parent_id ()
  | Post_board_vote { post_id; direction } ->
      Wire_knowledge.encode_board_vote ~post_id ~direction
  | Post_board_comment_vote { post_id = _; comment_id; direction } ->
      Wire_knowledge.encode_board_comment_vote ~comment_id ~direction
  | Post_artifact_check
      {
        expected_workspace;
        id;
        revision;
        body_sha256;
        checked;
        expected_change_id;
      } ->
      Wire_knowledge.encode_artifact_check_request ?expected_workspace ~id
        ~revision ~body_sha256 ~checked ~expected_change_id ()
  | Post_artifact_share
      {
        expected_workspace;
        id;
        shared;
        operation_id;
        expected_version;
        expected_artifact_revision;
        expected_artifact_sha256;
      } ->
      Wire_knowledge.encode_artifact_share_request ~expected_workspace ~id
        ~shared ~operation_id ~expected_version ~expected_artifact_revision
        ~expected_artifact_sha256
  | Post_schedule_create req -> Wire_work.encode_schedule_create req
  | Post_connector_bind { connector = _; channel_id; keeper_name } ->
      Wire_runtime.encode_connector_bind ~channel_id ~keeper_name
  | Post_connector_unbind { connector = _; channel_id; keeper_name } ->
      let base = [ ("channel_id", `String channel_id) ] in
      let fields =
        match keeper_name with
        | Some k when not (String.equal (String.trim k) "") ->
            base @ [ ("keeper_name", `String (String.trim k)) ]
        | Some _ | None -> base
      in
      `Assoc fields
  | Post_repo_add { url; branch } ->
      let base = [ ("url", `String url) ] in
      let fields =
        match branch with
        | Some b when not (String.equal (String.trim b) "") ->
            base @ [ ("default_branch", `String (String.trim b)) ]
        | Some _ | None -> base
      in
      `Assoc fields
  | Post_task_cancel { task_id; reason; expected_workspace } ->
      Wire_work.encode_task_cancel ~task_id ~reason ~expected_workspace
  | Post_harness_overrule { notes_hash; verdict; reason } ->
      let verdict_str =
        match verdict with `Approve -> "approve" | `Reject -> "reject"
      in
      `Assoc
        [
          ("notes_hash", `String notes_hash);
          ("verdict", `String verdict_str);
          ("reason", `String reason);
        ]
  | Post_browser_tabs { client_id } ->
      Wire_runtime.encode_browser_tabs_request ~client_id
  | Post_oauth_login { provider; _ }
  | Post_oauth_identity_refresh { provider; _ } ->
      Wire_keeper_context.encode_oauth_provider_body ~provider
  | Post_oauth_identity_switch { provider; enabled; _ } ->
      Wire_keeper_context.encode_oauth_switch_body ~provider ~enabled
  | Post_oauth_disconnect { keeper; provider } ->
      Wire_keeper_context.encode_oauth_disconnect_body ~keeper ~provider
  | Post_board_recovery item ->
      Board_quarantine.request_to_json
        { candidate_id = item.candidate_id; expected_quarantine_id = item.quarantine_id;
          decision = Acknowledge_and_requeue }
  | Post_github_token { token; hostname; _ } ->
      Wire_keeper_context.encode_github_token_body ~token ?hostname ()
  | Post_task_create { title; priority; description; goal_id; expected_workspace } ->
      let arguments =
        Wire_work.encode_task_create ~title ~priority ?description ?goal_id
          ?expected_workspace ()
      in
      Wire_work.encode_mcp_tool_call ~id:"tui-task-create"
        ~tool_name:"masc_add_task" ~arguments
  | Post_task_transition { task_id; action; notes; expected_workspace } ->
      let arguments =
        Wire_work.encode_task_transition ~task_id ~action ?notes
          ?expected_workspace ()
      in
      Wire_work.encode_mcp_tool_call ~id:"tui-task-transition"
        ~tool_name:"masc_transition" ~arguments
  | Post_task_link_goal { task_id = _; goal_id; expected_workspace } ->
      Wire_work.encode_task_link_goal ~goal_id ~expected_workspace
  | Post_goal_upsert
      { id; title; measure; procedure; priority; due_date; expected_workspace }
    ->
      let arguments =
        Wire_work.encode_goal_upsert ?id ~title ?measure ~procedure ?priority
          ?due_date ?expected_workspace ()
      in
      Wire_work.encode_mcp_tool_call ~id:"tui-goal-upsert"
        ~tool_name:"masc_goal_upsert" ~arguments
  | Post_board_pin { post_id; pinned } ->
      Wire_knowledge.encode_board_pin ~post_id ~pinned
  | Post_board_delete { post_id } ->
      Wire_knowledge.encode_board_delete ~post_id
  | Post_keeper_lifecycle { keeper = _; op; expected_workspace; from_modal = _ }
    ->
      Wire_fleet.encode_keeper_lifecycle_body ?expected_workspace op
  | Post_keeper_purge { keeper; expected_workspace } ->
      Wire_fleet.encode_keeper_purge ~agent_name:keeper ~expected_workspace
  | Post_lane_addon_attach { manifest_path; run_id; binding } ->
      Wire_runtime.encode_lane_addon_attach ~manifest_path ~run_id ~binding
  | Post_lane_addon_detach { instance_id } ->
      Wire_runtime.encode_lane_addon_detach ~instance_id
  | Post_lane_addon_action
      { instance_id; expected_incarnation; request_id; action } ->
      Wire_runtime.encode_lane_addon_action ~instance_id ~expected_incarnation
        ~request_id ~action
  | Post_lane_addon_ask_answer { declaration_id; ask_id; answers } ->
      Wire_runtime.encode_lane_addon_ask_answer ~declaration_id ~ask_id
        ~answers ()
  | Post_keeper_control_lifecycle { action = `Up; expected_workspace; _ } ->
      Wire_keeper_context.encode_keeper_up_body ?expected_workspace ()
  | Post_keeper_control_lifecycle { action = `Boot | `Shutdown | `Reset; _ } ->
      `Assoc []
  | Post_keeper_clear { reason; preserve_system_prompt; _ } ->
      Wire_keeper_context.encode_keeper_clear_body ~reason ~preserve_system_prompt
  | Post_keeper_directive { directive; expected_workspace; _ } ->
      Wire_keeper_context.encode_keeper_directive_body ~expected_workspace
        directive
  | Post_keeper_checkpoints { action = `Preview_purge; _ } ->
      Wire_keeper_context.encode_checkpoint_purge_body ~apply:false
  | Post_keeper_checkpoints { action = `Apply_purge; _ } ->
      Wire_keeper_context.encode_checkpoint_purge_body ~apply:true
  | Post_keeper_checkpoints { action = `Delete_history snapshot_ids; _ } ->
      Wire_keeper_context.encode_checkpoint_delete_history_body ~snapshot_ids
  | Post_keeper_operator_note { text; _ } ->
      Wire_keeper_context.encode_operator_note_body ~text
  | Post_keeper_run_next { keeper; request_id; interrupt_token } ->
      Wire_keeper_context.encode_keeper_run_next_body ~keeper ~request_id
        ?interrupt_token ()
  | Post_gate_resolution_policy
      { id; approved; reason; remember_rule; rule_expires_at; expected_workspace }
    ->
      Wire_work.encode_gate_resolution_with_policy ~id ~approved ~reason
        ~remember_rule ?rule_expires_at ?expected_workspace ()
  | Post_gate_mode { mode; _ } -> Wire_work.encode_gate_mode ~mode
  | Post_gate_rule_delete { id } -> Wire_work.encode_gate_rule_delete ~id
  | Post_gate_retry { meta; expected_workspace } ->
      Wire_work.encode_gate_retry ?expected_workspace meta
  | Post_keeper_tool_approval_mode { keeper; mode } ->
      Wire_work.encode_tool_approval_mode_set ~keeper ~mode
  | Post_hitl_ack_uncertain { keeper; consume_id } ->
      Wire_work.encode_hitl_ack_uncertain ~keeper_name:keeper ~consume_id
  | Post_hitl_late_approval_restore -> `Assoc []
  | Post_mcp_tools_list { rpc_id } ->
      Wire_runtime.encode_mcp_tools_list_body ~id:rpc_id
  | Post_mcp_tools_call { rpc_id; tool_name; arguments } ->
      Wire_runtime.encode_mcp_tools_call_body ~id:rpc_id ~tool_name ~arguments

let put_request_path = function
  | Put_wiki_page { page; _ } -> Wire_knowledge.wiki_page_path ~page

let put_request_body = function
  | Put_wiki_page { request; _ } -> Wire_knowledge.encode_wiki_put_request request

let rec flatten_one acc = function
  | Batch xs -> List.fold_left flatten_one acc xs
  | ( Http_get _
    | Http_post _
    | Http_put _
    | Http_post_stream _
    | Sync_streams _
    | Update_workspace_guard _
    | Voice_cmd _
    | Copy_clipboard _
    | Render_memory_diagram _
    | Cancel_memory_diagram
    | Fetch_artifact_and_copy _
    | Export_artifact _
    | Open_dos_screen _
    | Open_external_url _
    | Open_editor_escape_hatch _
    | Start_local_server
    | Restart_tui
    | Quit _ ) as cmd ->
      cmd :: acc

let flatten cmds = List.rev (List.fold_left flatten_one [] cmds)
