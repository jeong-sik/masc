open Masc_tui_core
open Masc_tui_protocol

type get_request =
  | Get_health
  | Get_dashboard_shell
  | Get_keepers_roster
  | Get_keeper_turns
  | Get_chat_history of {
      keeper : string;
      limit : int option;
      cursor : string option;
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
  | Get_board_thread of { post_id : string; comment_limit : int option }
  | Get_quarantines of { keeper : string }
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
  | Get_world_memory
  | Get_memory_diff of {
      keeper : string option;
      window : Knowledge_store.memory_diff_window;
    }
  | Get_keeper_memory_os_internals of { keeper : string }
  | Get_keeper_memory_facts of { keeper : string }
  | Get_keeper_memory_activity of { keeper : string; limit : int }
  | Get_keeper_memory_health
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
  | Get_tools_catalog of { keeper : string option }
  | Get_connectors
  | Get_browser_lane
  | Get_mcp_clients
  | Get_sandboxes
  | Get_keeper_sandbox of { keeper : string }
  | Get_repositories
  | Get_file_changes of { keeper : string; window_hours : float option }
  | Get_system_logs of {
      limit : int option;
      level : Wire_infra.log_level option;
    }
  | Get_tui_preferences
  | Get_config_schema of Wire_config.config_target

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
    }
  | Post_goal_confirmation of Wire_work.goal_confirmation_request
  | Post_verification_verdict of {
      task_id : string;
      verification_id : string;
      verdict : Wire_work.operator_verdict;
      notes : string option;
    }
  | Post_quarantine_requeue of {
      keeper : string;
      partition_id : string;
      quarantine_id : string;
      reason : string option;
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
  | Post_setup_account_key of {
      integration_id : string;
      key : string;
      source_revision : string;
    }
  | Post_setup_login_start of {
      integration_id : string;
      account_ref : string option;
    }
  | Post_sandbox_probe of [ `All | `Keeper of string | `Ssh_pool of string ]
  | Post_config_patch of Wire_config.patch_request
  | Post_tui_preference of Wire_config.tui_preference_change
  | Post_keeper_turn_interrupt of {
      keeper : string;
      target : [ `Turn_token of string | `Operation_id of string ];
    }
  | Post_board_create of {
      title : string;
      body : string;
      hearth : string option;
    }
  | Post_schedule_create of {
      keeper : string;
      recurrence : string;
      prompt : string;
    }
  | Post_connector_create of { connector : string; channel : string }
  | Post_repo_add of { url : string; branch : string option }
  | Post_task_cancel of { task_id : string; reason : string option }
  | Post_harness_overrule of { target_id : string; reason : string }

type put_request =
  | Put_wiki_page of { page : string; request : Wire_knowledge.wiki_put_request }

type stream_post_request =
  | Stream_keeper_chat of {
      request : Wire_fleet.chat_submit_request;
      is_btw : bool;
    }

type voice_cmd =
  | Start_ptt of { device : string option }
  | Stop_ptt
  | Cancel_ptt
  | Speak of { text : string; voice_id : string option }
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
      ko : bool;
      tz_offset_sec : int;
      now_unix : float;
      max_width : int;
      chart : Masc_tui_ui.Memory_lineage.chart;
    }
  | Cancel_memory_diagram
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
  | Get_chat_history { keeper; limit; cursor } ->
      Wire_fleet.keeper_chat_history_page_path ~keeper ?limit ?cursor ()
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
  | Get_board_thread { post_id; comment_limit } ->
      Wire_knowledge.board_post_path ~post_id ?comment_limit ()
  | Get_quarantines { keeper } ->
      Wire_knowledge.keeper_quarantines_path ~keeper
  | Get_wiki_index { tag; source; sort } ->
      Wire_knowledge.wiki_index_path ?tag ?source ?sort ()
  | Get_wiki_page { page } -> Wire_knowledge.wiki_page_path ~page
  | Get_wiki_log { limit; page } ->
      Wire_knowledge.wiki_log_path ?limit ?page ()
  | Get_wiki_search { query; limit } ->
      Wire_knowledge.wiki_search_path ~query ?limit ()
  | Get_wiki_lint -> Wire_knowledge.wiki_lint_path
  | Get_artifacts -> "/api/v1/published-artifacts"
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
  | Get_keeper_memory_health ->
      Wire_knowledge.keeper_memory_health_path ()
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
  | Get_tools_catalog { keeper } -> Wire_runtime.dashboard_tools_path ?keeper ()
  | Get_connectors -> Wire_runtime.connectors_path
  | Get_browser_lane -> Wire_runtime.browser_lane_path
  | Get_mcp_clients -> Wire_runtime.mcp_clients_path
  | Get_sandboxes -> Wire_infra.infra_sandboxes_path
  | Get_keeper_sandbox { keeper } ->
      Wire_infra.infra_sandbox_keeper_path ~keeper
  | Get_repositories -> Wire_infra.repositories_path
  | Get_file_changes { keeper; window_hours } ->
      Wire_infra.keeper_file_changes_path ~keeper ?window_hours ()
  | Get_system_logs { limit; level } ->
      let level = Option.map Wire_infra.log_level_to_string level in
      Wire_infra.system_logs_path ?limit ?level ()
  | Get_tui_preferences -> Wire_config.tui_preferences_path
  | Get_config_schema target -> Wire_config.config_schema_path target

let post_request_path = function
  | Post_ask_answer _ -> Wire_work.keeper_ask_answer_path
  | Post_tool_approval _ -> Wire_work.keeper_tool_approval_path
  | Post_gate_resolution _ -> "/api/v1/dashboard/gate/resolve"
  | Post_goal_transition _ -> "/api/v1/tools/masc_goal_transition"
  | Post_goal_confirmation _ -> Wire_work.goal_confirmation_path
  | Post_verification_verdict _ -> Wire_work.verification_verdict_path
  | Post_quarantine_requeue { keeper; partition_id; _ } ->
      Wire_knowledge.keeper_quarantine_requeue_path ~keeper ~partition_id
  | Post_memory_act { keeper; _ } ->
      Wire_knowledge.keeper_memory_act_path ~keeper
  | Post_fusion_launch { keeper; _ } -> Wire_runtime.fusion_launch_path ~keeper
  | Post_runtime_assignment _ -> Wire_runtime.runtime_assignment_path
  | Post_runtime_default_route _ -> Wire_runtime.runtime_routing_path
  | Post_setup_account_key _ -> Wire_runtime.setup_credential_path
  | Post_setup_login_start _ -> Wire_runtime.setup_accounts_login_path
  | Post_sandbox_probe _ -> Wire_infra.infra_sandboxes_probe_path
  | Post_config_patch _ -> Wire_config.config_patch_path
  | Post_tui_preference _ -> Wire_config.tui_preferences_path
  | Post_keeper_turn_interrupt _ -> Wire_fleet.keeper_turn_interrupt_path
  | Post_board_create _ -> "/api/v1/tools/masc_board_post"
  | Post_schedule_create _ -> "/api/v1/tools/masc_schedule_create"
  | Post_connector_create _ -> "/api/v1/gate/connector/bind"
  | Post_repo_add _ -> Wire_infra.repositories_path
  | Post_task_cancel _ -> "/api/v1/dashboard/tasks/cancel"
  | Post_harness_overrule _ -> "/api/v1/dashboard/harness-label"

let post_request_body = function
  | Post_ask_answer { keeper; ask_id; answers } ->
      Wire_work.encode_ask_answer ~keeper ~ask_id ~answers ()
  | Post_tool_approval
      { keeper; tool_call_id; approval_id; decision; expected_workspace } ->
      Wire_work.encode_tool_approval_decision ~keeper ~tool_call_id ~approval_id
        ~decision ?expected_workspace ()
  | Post_gate_resolution { id; approved; reason } ->
      Wire_work.encode_gate_resolution ~id ~approved ~reason
  | Post_goal_transition { goal_id; action; note } ->
      Wire_work.encode_goal_transition ~goal_id ~action ~note
  | Post_goal_confirmation req -> Wire_work.encode_goal_confirmation req
  | Post_verification_verdict { task_id; verification_id; verdict; notes } ->
      Wire_work.encode_verification_verdict ~task_id ~verification_id ~verdict
        ~notes
  | Post_quarantine_requeue { quarantine_id; reason; _ } ->
      Wire_knowledge.encode_quarantine_requeue_request ~quarantine_id ~reason
  | Post_memory_act { act; _ } -> Wire_knowledge.encode_memory_act_request act
  | Post_fusion_launch { request; _ } -> Wire_runtime.encode_fusion_launch request
  | Post_runtime_assignment
      { keeper_name; runtime_id; source_revision; previous_runtime_id } ->
      Wire_runtime.encode_runtime_assignment ~keeper_name ~runtime_id
        ~source_revision ~previous_runtime_id ()
  | Post_runtime_default_route { runtime_id } ->
      Wire_runtime.encode_runtime_default_route ~runtime_id
  | Post_setup_account_key { integration_id; key; source_revision } ->
      Wire_runtime.encode_setup_credential ~provider_id:integration_id
        ~secret:key ~source_revision
  | Post_setup_login_start { integration_id; account_ref } ->
      Wire_runtime.encode_setup_account_login_start ~integration_id ?account_ref
        ()
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
  | Post_schedule_create { keeper; recurrence; prompt } ->
      `Assoc
        [
          ("keeper", `String keeper);
          ("recurrence", `String recurrence);
          ("prompt", `String prompt);
        ]
  | Post_connector_create { connector; channel } ->
      `Assoc [ ("connector", `String connector); ("channel", `String channel) ]
  | Post_repo_add { url; branch } ->
      let base = [ ("url", `String url) ] in
      let fields =
        match branch with
        | Some b when not (String.equal (String.trim b) "") ->
            base @ [ ("default_branch", `String (String.trim b)) ]
        | Some _ | None -> base
      in
      `Assoc fields
  | Post_task_cancel { task_id; reason } ->
      let base = [ ("task_id", `String task_id) ] in
      let fields =
        match reason with
        | Some r when not (String.equal (String.trim r) "") ->
            base @ [ ("reason", `String (String.trim r)) ]
        | Some _ | None -> base
      in
      `Assoc fields
  | Post_harness_overrule { target_id; reason } ->
      `Assoc [ ("target_id", `String target_id); ("reason", `String reason) ]

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
    | Open_external_url _
    | Open_editor_escape_hatch _
    | Start_local_server
    | Restart_tui
    | Quit _ ) as cmd ->
      cmd :: acc

let flatten cmds = List.rev (List.fold_left flatten_one [] cmds)
