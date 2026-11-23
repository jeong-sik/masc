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
      expected_workspace : Wire_work.expected_workspace;
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
  | Post_task_cancel of {
      task_id : string;
      reason : string option;
      expected_workspace : Wire_work.expected_workspace;
    }
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

val get_request_path : get_request -> string
val post_request_path : post_request -> string
val post_request_body : post_request -> Yojson.Safe.t
val put_request_path : put_request -> string
val put_request_body : put_request -> Yojson.Safe.t
val flatten : t list -> t list
