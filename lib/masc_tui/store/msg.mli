(** Closed sum type for every event delivered into {!Update.step}.

    All asynchronous replies carry their originating {!Epoch.t} so late replies
    from prior epochs or workspace handshakes are dropped in one guard. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

type http_error =
  | Transport of Health.transport_error
  | Workspace_mismatch of {
      expected_instance : string option;
      observed_instance : string option;
      observed_workspace_sha256 : string option;
      message : string;
    }
  | Http_error of {
      status : int;
      body : string;
      api_error : Wire_common.api_error option;
    }
  | Decode_error of string

val http_error_summary : http_error -> Say.t
val http_error_detail : http_error -> string

type http_reply =
  (* Fleet & Pulse *)
  | Reply_dashboard_shell of (Wire_fleet.dashboard_shell, http_error) result
  | Reply_keepers_roster of (Wire_fleet.keeper_summary list, http_error) result
  | Reply_keepers_roster_extras of Wire_fleet.keeper_roster_extras
  | Reply_execution_enrichments of
      (Wire_fleet.execution_keeper_enrichment list
      * Wire_fleet.candle_summary_fallback option)
  | Reply_keeper_turns of (Wire_fleet.keeper_turn_row list, http_error) result
  | Reply_chat_history of {
      keeper : string;
      result : (Wire_fleet.chat_history_page, http_error) result;
    }
  | Reply_turn_interrupt of {
      keeper : string;
      result : (Wire_fleet.turn_interrupt_response, http_error) result;
    }
  (* Work *)
  | Reply_planning of (Wire_work.planning_snapshot, http_error) result
  | Reply_planning_backlog of Wire_work.task_backlog_counts
  | Reply_verifications of
      (Wire_work.verification_request list, http_error) result
  | Reply_schedules of
      (Wire_work.schedule_row list * string option, http_error) result
  | Reply_asks of (Wire_work.ask_row list, http_error) result
  | Reply_tool_approvals of
      (Wire_work.held_tool_approval list, http_error) result
  | Reply_gate_pending of (Wire_work.gate_pending list, http_error) result
  | Reply_candle_ledger of (Wire_work.candle_ledger, http_error) result
  | Reply_work_mutation of {
      label : Say.t;
      attention_id : string option;
      decision_kind : Work_store.decision_kind option;
      target_id : string option;
      keeper : string option;
      result : (unit, http_error) result;
    }
  (* Knowledge *)
  | Reply_board_feed of (Wire_knowledge.board_feed, http_error) result
  | Reply_board_thread of
      ( Wire_knowledge.board_post * Wire_knowledge.board_comment list
      , http_error )
      result
  | Reply_quarantines of
      (Wire_knowledge.quarantine_candidate list, http_error) result
  | Reply_wiki_index of (Wire_knowledge.wiki_index, http_error) result
  | Reply_wiki_page of (Wire_knowledge.wiki_page_detail, http_error) result
  | Reply_wiki_log of (Wire_knowledge.wiki_log_response, http_error) result
  | Reply_wiki_search of
      (Wire_knowledge.wiki_search_response, http_error) result
  | Reply_wiki_lint of (Wire_knowledge.wiki_lint_report, http_error) result
  | Reply_wiki_put of {
      page : string;
      result : (Wire_knowledge.wiki_page_detail, http_error) result;
    }
  | Reply_artifacts of (Wire_knowledge.artifact_entry list, http_error) result
  | Reply_world_memory of (Wire_knowledge.world_memory, http_error) result
  | Reply_memory_diff of (Wire_knowledge.memory_diff, http_error) result
  | Reply_keeper_memory_os_internals of
      (Wire_knowledge.memory_os_internals, http_error) result
  | Reply_memory_act of {
      keeper : string;
      result : (Wire_knowledge.memory_act_answer, http_error) result;
    }
  (* Runtime *)
  | Reply_provider_usage of
      (Wire_runtime.provider_usage_windows, http_error) result
  | Reply_provider_usage_history of
      (Wire_runtime.provider_usage_history, http_error) result
  | Reply_keeper_costs of (Wire_runtime.keeper_costs_window, http_error) result
  | Reply_efficiency of (Wire_runtime.efficiency_month, http_error) result
  | Reply_models_metrics of
      (Wire_runtime.models_metrics_snapshot, http_error) result
  | Reply_runtime_metrics of
      (Wire_runtime.runtime_metrics_snapshot, http_error) result
  | Reply_runtime_resolved of
      (Wire_runtime.runtime_resolved_snapshot, http_error) result
  | Reply_runtime_config_raw of
      (Wire_runtime.runtime_config_raw_meta, http_error) result
  | Reply_setup_inventory of (Wire_runtime.setup_inventory, http_error) result
  | Reply_setup_login_receipt of
      (Wire_runtime.setup_login_receipt, http_error) result
  | Reply_runtime_assignment of {
      keeper_name : string;
      runtime_id : string option;
      result : (unit, http_error) result;
    }
  | Reply_runtime_routing of {
      runtime_id : string;
      result : (unit, http_error) result;
    }
  | Reply_setup_account_key of {
      integration_id : string;
      result : (unit, http_error) result;
    }
  | Reply_runtime_probe of
      (Wire_runtime.runtime_probe_snapshot, http_error) result
  | Reply_exact_lane_runs of
      (Wire_runtime.exact_lane_run list, http_error) result
  | Reply_fusion_runs of (Wire_runtime.fusion_run list, http_error) result
  | Reply_fusion_launch of (unit, http_error) result
  | Reply_tool_series of (Wire_runtime.tool_series, http_error) result
  | Reply_tools_catalog of (Wire_runtime.tool_summary list, http_error) result
  | Reply_connectors of (Wire_runtime.connector_row list, http_error) result
  | Reply_browser_lane of
      (Wire_runtime.browser_lane_status, http_error) result
  | Reply_mcp_clients of (Wire_runtime.mcp_client_row list, http_error) result
  (* Infra *)
  | Reply_sandboxes of (Wire_infra.sandboxes_snapshot, http_error) result
  | Reply_keeper_sandbox of
      (Wire_infra.keeper_sandbox_response, http_error) result
  | Reply_repositories of (Wire_infra.repository list, http_error) result
  | Reply_file_changes of {
      keeper : string;
      result : (Wire_infra.file_change list, http_error) result;
    }
  | Reply_system_logs of (Wire_infra.system_log_entry list, http_error) result
  (* Config & Generic Mutations *)
  | Reply_tui_preferences of (Wire_config.tui_preferences, http_error) result
  | Reply_config_schema of (Wire_config.config_schema, http_error) result
  | Reply_config_schema_meta of {
      target : Wire_config.config_target;
      meta : (string * Wire_config.field_entity_meta) list;
    }
  | Reply_config_patch of {
      dry_run : bool;
      result : (Wire_config.patch_response, http_error) result;
    }
  | Reply_action_ack of { label : Say.t; result : (unit, http_error) result }

type sse_event =
  | Sse_observer_handshake of Wire_observer.handshake_result
  | Sse_observer_delivery of Wire_observer.delivery
  | Sse_fleet of Wire_fleet.fleet_stream_event
  | Sse_log_entry of Wire_infra.system_log_entry
  | Sse_model_metrics of Wire_runtime.efficiency_month
  | Sse_models_metrics_snapshot of Wire_runtime.models_metrics_snapshot
  | Sse_tool_series of Wire_runtime.tool_series

type voice_event =
  | Voice_started
  | Voice_level of float
  | Voice_transcribing
  | Voice_speaking
  | Voice_idle
  | Voice_transcript of string
  | Voice_capabilities of Drafts.voice_capabilities
  | Voice_failed of string

type t =
  | Boot
  | Key_event of Keymap.Input.key_event
  | Paste_text of string
  | Mouse_event of Keymap.Input.mouse_event
  | Resize of { cols : int; rows : int }
  | Tick of { wall_unix : float }
  | Server_health_result of {
      epoch : Epoch.t;
      result : (Wire_common.server_health, http_error) result;
    }
  | Server_start_result of (unit, string) result
  | Http_reply of { epoch : Epoch.t; reply : http_reply }
  | Sse_event of { epoch : Epoch.t; event : sse_event }
  | Sse_freshness of {
      epoch : Epoch.t;
      stream : Subscriptions.stream_id;
      freshness : Health.source_freshness;
    }
  | Chat_stream_chunk of {
      epoch : Epoch.t;
      keeper : string;
      request_id : string;
      is_btw : bool;
      chunk : Wire_fleet.chat_stream_chunk;
    }
  | Chat_stream_decode_warning of {
      epoch : Epoch.t;
      keeper : string;
      request_id : string;
      reason : string;
    }
  | Chat_stream_done of {
      epoch : Epoch.t;
      keeper : string;
      request_id : string;
      is_btw : bool;
      result : (unit, http_error) result;
    }
  | Voice_event of voice_event
  | Stream_gap of int
