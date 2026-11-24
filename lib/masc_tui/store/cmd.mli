(** Closed sum type of all declarative side effects emitted by {!Update.step}.

    The store never performs network, filesystem, audio, or terminal I/O
    directly; every effect is described as a typed value executed by
    [masc_tui_app]. *)

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
  (* Wave 3: Fusion, Harness, Verification Evidence, Activity/Trace, Code, Memory, Keeper Logs & Identity *)
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
  (* Wave 4 Layer 1: Per-Turn Flow, Checkpoints, Operator Note *)
  | Get_keeper_turn_flow of {
      keeper : string;
      trace_id : string;
      turn_id : int;
      turn_ref : string;
    }
  | Get_keeper_checkpoints of { keeper : string }
  | Get_keeper_operator_note of { keeper : string }
  (* Wave 4 Layer 2: HITL Gate, Tool Approval Modes, Tool Quality, Waiting Inventory *)
  | Get_tool_approval_modes
  | Get_late_approval_attempts
  | Get_tool_quality of { n : int option; window_hours : int option }
  | Get_gate_tool_events of { window_minutes : int option }
  | Get_keeper_waiting_inventory of { keeper : string }
  (* Wave 4 Layer 3: Skill Editor, Async Requests, Prompts, Presets & Runtime Params *)
  | Get_skill_editor_sources
  | Get_skill_editor_tools
  | Get_async_requests
  | Get_prompts
  | Get_presets
  | Get_preset_show of { name : string }
  | Get_runtime_params
  (* Wave 4 Layer 4: Lanes Inventory, Standalone Lanes, Exact Run Detail, Verifier Runs, Quarantines & Lane Add-ons *)
  | Get_lanes_inventory
  | Get_standalone_lanes
  | Get_exact_lane_run_detail of { run_id : string }
  | Get_verification_runs
  | Get_goal_verification_runs
  | Get_keeper_board_attention_quarantines of { keeper : string }
  | Get_lane_addon_declaration of { source_path : string }
  | Get_lane_addon_action_status of {
      instance_id : string;
      request_id : string;
    }
  | Get_lane_addon_slice of {
      run_id : string option;
      lane_id : string option;
    }
  | Get_lane_addon_asks of { include_resolved : bool }

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
      from_modal : bool;
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
  (* Wave 4 Layer 1: Keeper Lifecycle, Checkpoints, Operator Note & Run-Next *)
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
  (* Wave 4 Layer 2: HITL Gate Policy/Rules/Modes/Retry/Recovery & Stateless MCP Executor *)
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
  (* Wave 4 Layer 3: Skill Editor, Prompts, Presets & Runtime Params *)
  | Post_skill_editor_read of {
      reference : string;
      reference_json : Yojson.Safe.t;
    }
  | Post_skill_editor_preview_new of {
      source_id : string;
      package_id : string;
      kind : [ `Instruction | `Composition ];
      source_text : string;
    }
  | Post_skill_editor_create of {
      source_id : string;
      package_id : string;
      kind : [ `Instruction | `Composition ];
      source_text : string;
    }
  | Post_skill_editor_preview of {
      reference : string;
      reference_json : Yojson.Safe.t;
      source_text : string;
    }
  | Post_skill_editor_save of {
      reference : string;
      reference_json : Yojson.Safe.t;
      source_text : string;
    }
  | Post_skills_refresh
  | Post_prompt_override of { key : string; value : string option }
  | Post_preset_save of { name : string; description : string }
  | Post_preset_create of { name : string; description : string }
  | Post_preset_restore of { name : string }
  | Post_preset_delete of { name : string }
  | Post_runtime_param_set of { param_key : string; value : Yojson.Safe.t }
  | Post_runtime_param_clear of { param_key : string }
  (* Wave 4 Layer 4: Runtime Routing CRUD, Raw Preview, Quarantine Recovery, Lane Add-ons & Browser Operator *)
  | Post_runtime_routing_action of {
      action : Wire_runtime.runtime_routing_action;
      label : Say.t;
    }
  | Post_runtime_config_raw_preview of { source_text : string }
  | Post_board_attention_quarantine_recovery of {
      keeper : string;
      partition_id : string;
      candidate_id : string;
      expected_quarantine_id : string;
    }
  | Post_lane_addon_declaration_save of {
      mode : [ `Create | `Save ];
      file_name : string;
      source_text : string;
      expected_source_revision : string option;
    }
  | Post_lane_addon_observe of { instance_id : string }
  | Post_lane_addon_retain of { instance_id : string }
  | Post_lane_addon_evidence of {
      instance_id : string;
      row_ids : string list;
      keeper_name : string option;
      broadcast : bool;
      request_id : string option;
    }
  | Post_lane_addon_act of {
      instance_id : string;
      expected_incarnation : string;
      request_id : string;
      action : Yojson.Safe.t;
    }
  | Post_lane_addon_operator of {
      instance_id : string;
      expected_incarnation : string;
      mode : Wire_runtime.addon_operator_mode;
    }
  | Post_browser_scene of {
      client_id : string;
      tab_id : int;
      view : [ `Content | `Regions ];
    }
  | Post_browser_screenshot of { client_id : string; tab_id : int }
  | Post_browser_command of { arguments : Yojson.Safe.t }
  | Post_browser_interact of {
      client_id : string;
      tab_id : int;
      expected_url : string option;
      action : string;
      selector : string option;
      text : string option;
      x : int option;
      y : int option;
    }

type put_request =
  | Put_wiki_page of { page : string; request : Wire_knowledge.wiki_put_request }

type delete_request =
  | Delete_skill_editor of {
      reference : string;
      reference_json : Yojson.Safe.t;
      confirmed : bool;
    }

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
  | Http_delete of { epoch : Epoch.t; req : delete_request }
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

val get_request_path : get_request -> string
val post_request_path : post_request -> string
val post_request_body : post_request -> Yojson.Safe.t
val mcp_tool_name_of_post_request : post_request -> string option
val put_request_path : put_request -> string
val put_request_body : put_request -> Yojson.Safe.t
val delete_request_path : delete_request -> string
val delete_request_body : delete_request -> Yojson.Safe.t
val flatten : t list -> t list
