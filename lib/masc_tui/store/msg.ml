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

let transport_error_detail = function
  | Health.Connect_refused -> "connection refused"
  | Health.Timeout -> "request timed out"
  | Health.Timeout_detail { phase; after_sec; path } ->
      Say.resolve Say.Lang_en
        (Health.timeout_detail_say ~phase ~after_sec ~path)
  | Health.Http_status code -> Printf.sprintf "HTTP %d" code
  | Health.Stream_eof -> "stream closed unexpectedly (EOF)"
  | Health.Protocol_error s -> "protocol error: " ^ s
  | Health.Other_io s -> "I/O error: " ^ s

let rec extract_json_error_text (json : Yojson.Safe.t) : string option =
  let nonblank s =
    let t = String.trim s in
    if String.equal t "" then None else Some t
  in
  let unwrap_maybe_json_string s =
    match nonblank s with
    | None -> None
    | Some t ->
        if String.length t >= 2 && Char.equal t.[0] '{' then
          match Yojson.Safe.from_string t with
          | inner -> (
              match extract_json_error_text inner with
              | Some reason -> Some reason
              | None -> Some t)
          | exception Yojson.Json_error _ -> Some t
        else Some t
  in
  match json with
  | `Assoc fields -> (
      let lookup k = List.assoc_opt k fields in
      let from_field k =
        match lookup k with
        | Some (`String s) -> unwrap_maybe_json_string s
        | Some (`Assoc _ as sub) -> extract_json_error_text sub
        | Some _ | None -> None
      in
      match from_field "message" with
      | Some _ as ok -> ok
      | None -> (
          match from_field "error" with
          | Some _ as ok -> ok
          | None -> (
              match from_field "operator_action" with
              | Some _ as ok -> ok
              | None -> (
                  match from_field "detail" with
                  | Some _ as ok -> ok
                  | None -> (
                      match from_field "code" with
                      | Some _ as ok -> ok
                      | None -> from_field "error_code")))))
  | `String s -> unwrap_maybe_json_string s
  | `List _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Null -> None

let extract_http_error_reason ~body ~(api_error : Wire_common.api_error option)
    : string option =
  let sanitize s =
    let s =
      String.map
        (fun c -> if Char.equal c '\n' || Char.equal c '\r' || Char.equal c '\t' then ' ' else c)
        (String.trim s)
    in
    if String.equal s "" then None
    else if Masc_tui_term.Grapheme.display_width s > 140 then
      Some (Masc_tui_term.Grapheme.truncate_to_width ~max_width:140 s)
    else Some s
  in
  let from_api =
    match api_error with
    | Some err -> (
        match extract_json_error_text (`String err.message) with
        | Some reason -> sanitize reason
        | None -> sanitize err.message)
    | None -> None
  in
  match from_api with
  | Some _ as ok -> ok
  | None -> (
      let trimmed = String.trim body in
      if String.equal trimmed "" then None
      else
        match Yojson.Safe.from_string trimmed with
        | json -> (
            match extract_json_error_text json with
            | Some reason -> sanitize reason
            | None -> None)
        | exception Yojson.Json_error _ ->
            (* Only surface short plain-text bodies, never raw HTML pages. *)
            if String.length trimmed > 0 && Char.equal trimmed.[0] '<' then None
            else sanitize trimmed)

let http_error_summary = function
  | Transport Health.Connect_refused ->
      Say.make ~ko:"서버 연결 거부" ~en:"Server connection refused"
  | Transport Health.Timeout ->
      Say.make ~ko:"요청 시간 초과" ~en:"Request timed out"
  | Transport (Health.Timeout_detail { phase; after_sec; path }) ->
      Health.timeout_detail_say ~phase ~after_sec ~path
  | Transport (Health.Http_status code) ->
      Say.make
        ~ko:(Printf.sprintf "HTTP %d 오류" code)
        ~en:(Printf.sprintf "HTTP %d error" code)
  | Transport Health.Stream_eof ->
      Say.make ~ko:"스트림 연결 종료" ~en:"Stream disconnected"
  | Transport (Health.Protocol_error _ | Health.Other_io _) ->
      Say.make ~ko:"전송 오류" ~en:"Transport error"
  | Workspace_mismatch _ ->
      Say.make ~ko:"워크스페이스 불일치 · 재동기화"
        ~en:"Workspace mismatch · resyncing"
  | Http_error { status; body; api_error } -> (
      match extract_http_error_reason ~body ~api_error with
      | Some reason ->
          Say.make
            ~ko:(Printf.sprintf "HTTP %d: %s" status reason)
            ~en:(Printf.sprintf "HTTP %d: %s" status reason)
      | None ->
          Say.make
            ~ko:(Printf.sprintf "API 오류 (HTTP %d)" status)
            ~en:(Printf.sprintf "API error (HTTP %d)" status))
  | Decode_error _ ->
      Say.make ~ko:"응답 디코드 오류" ~en:"Response decode error"

let http_error_detail = function
  | Transport te -> transport_error_detail te
  | Workspace_mismatch { expected_instance; observed_instance; message; _ } ->
      let exp = match expected_instance with Some s -> s | None -> "?" in
      let obs = match observed_instance with Some s -> s | None -> "?" in
      Printf.sprintf "workspace_mismatch (expected=%s observed=%s): %s" exp obs
        message
  | Http_error { status; body; api_error } -> (
      match api_error with
      | Some err ->
          Printf.sprintf "HTTP %d [%s]: %s" status
            (Wire_common.api_error_code_to_string err.code)
            err.message
      | None ->
          let snippet =
            if String.length body > 200 then String.sub body 0 200 ^ "..."
            else body
          in
          Printf.sprintf "HTTP %d: %s" status snippet)
  | Decode_error detail -> "decode error: " ^ detail

let http_error_retryable = function
  | Transport _ -> true
  | Http_error { status; _ } -> status >= 500 || status = 429
  | Workspace_mismatch _ | Decode_error _ -> false

type ack_effect =
  | Ack_toast_only
  | Ack_close_modal
  | Ack_refresh_view
  | Ack_close_modal_and_refresh
  | Ack_editor_saved

type http_reply =
  | Reply_dashboard_shell of (Wire_fleet.dashboard_shell, http_error) result
  | Reply_keepers_roster of (Wire_fleet.keepers_roster, http_error) result
  | Reply_keepers_roster_extras of Wire_fleet.keeper_roster_extras
  | Reply_execution_enrichments of
      (Wire_fleet.execution_keeper_enrichment list
      * Wire_fleet.candle_observation option)
  | Reply_keeper_turns of (Wire_fleet.keeper_turn_row list, http_error) result
  | Reply_keeper_turn_records of {
      keeper : string;
      result : (Wire_fleet.keeper_turn_records, http_error) result;
    }
  | Reply_chat_history of {
      keeper : string;
      result : (Wire_fleet.chat_history_page, http_error) result;
    }
  | Reply_chat_queue of {
      keeper : string;
      requested_at : Clock.Mono.t;
      operations : Wire_fleet.chat_operation list;
      result : (unit, http_error) result option;
    }
  | Reply_chat_absence of { keeper : string; operation_id : string; requested_at : Clock.Mono.t }
  | Reply_chat_status of {
      keeper : string;
      operation_id : string;
      requested_at : Clock.Mono.t;
      result : (Wire_fleet.chat_operation, http_error) result;
    }
  | Reply_chat_operation_events of {
      keeper : string;
      operation_id : string;
      from : Wire_chat_journal.from;
      result : (Wire_chat_journal.page, http_error) result;
    }
  | Reply_turn_interrupt of {
      keeper : string;
      target : Cmd.keeper_turn_interrupt_target;
      result : (Wire_fleet.turn_interrupt_response, http_error) result;
    }
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
  | Reply_tool_approval of {
      keeper : string;
      approval_id : string;
      attention_id : string;
      decision : Wire_work.tool_approval_decision;
      result : (Wire_work.tool_approval_outcome, http_error) result;
    }
  | Reply_board_feed of (Wire_knowledge.board_feed, http_error) result
  | Reply_board_hearths of
      (Wire_knowledge.board_hearth_entry list, http_error) result
  | Reply_board_thread of {
      post_id : string;
      result :
        ( Wire_knowledge.board_post * Wire_knowledge.board_comment list
        , http_error )
        result;
    }
  | Reply_board_comment of { post_id : string; result : (unit, http_error) result }
  | Reply_board_vote of { post_id : string; result : (unit, http_error) result }
  | Reply_board_delete of { post_id : string; result : (unit, http_error) result }
  | Reply_wiki_index of (Wire_knowledge.wiki_index, http_error) result
  | Reply_wiki_page of {
      page : string;
      result : (Wire_knowledge.wiki_page_detail, http_error) result;
    }
  | Reply_wiki_log of (Wire_knowledge.wiki_log_response, http_error) result
  | Reply_wiki_search of
      (Wire_knowledge.wiki_search_response, http_error) result
  | Reply_wiki_lint of (Wire_knowledge.wiki_lint_report, http_error) result
  | Reply_wiki_put of {
      page : string;
      result : (Wire_knowledge.wiki_put_result, http_error) result;
    }
  | Reply_artifacts of (Wire_knowledge.artifact_entry list, http_error) result
  | Reply_artifact_detail of {
      id : string;
      result : (Wire_knowledge.published_artifact_detail, http_error) result;
    }
  | Reply_artifact_checks of
      (Wire_knowledge.artifact_check list, http_error) result
  | Reply_artifact_check of {
      id : string;
      result : (Wire_knowledge.artifact_check, http_error) result;
    }
  | Reply_artifact_share of {
      id : string;
      result : (Wire_knowledge.artifact_share_result, http_error) result;
    }
  | Reply_world_memory of (Wire_knowledge.world_memory, http_error) result
  | Reply_memory_diff of {
      keeper : string option;
      window : Knowledge_store.memory_diff_window;
      result : (Wire_knowledge.memory_diff, http_error) result;
    }
  | Reply_keeper_memory_os_internals of {
      keeper : string;
      result : (Wire_knowledge.memory_os_internals, http_error) result;
    }
  | Reply_keeper_memory_facts of {
      keeper : string;
      result : (Wire_knowledge.keeper_memory_facts, http_error) result;
    }
  | Reply_keeper_memory_activity of {
      keeper : string;
      result : (Wire_knowledge.keeper_memory_activity, http_error) result;
    }
  | Reply_keeper_memory_health of
      (Wire_knowledge.keeper_memory_health_fleet, http_error) result
  | Reply_memory_act of {
      keeper : string;
      result : (Wire_knowledge.memory_act_answer, http_error) result;
    }
  | Reply_keeper_context_turn_records of {
      keeper : string;
      result : (Wire_keeper_context.turn_records_page, http_error) result;
    }
  | Reply_keeper_provider_input of {
      keeper : string;
      turn_ref : string;
      result : (Wire_keeper_context.provider_input_manifest, http_error) result;
    }
  | Reply_keeper_provider_input_part of {
      keeper : string;
      turn_ref : string;
      index : int;
      result :
        (Wire_keeper_context.provider_input_part_content, http_error) result;
    }
  | Reply_keeper_cache_outcome of {
      keeper : string;
      turn_ref : string;
      result : (Keeper_cache_outcome_reading.reading, http_error) result;
    }
  | Reply_keeper_next_request of {
      keeper : string;
      result : (Wire_keeper_context.next_request_forecast, http_error) result;
    }
  | Reply_keeper_turn_transcript of {
      keeper : string;
      turn_ref : string;
      result : (Wire_keeper_context.turn_transcript, http_error) result;
    }
  | Reply_keeper_tool_stats of {
      keeper : string;
      result : (Wire_keeper_context.keeper_tool_stats, http_error) result;
    }
  | Reply_keeper_tool_calls of {
      keeper : string;
      turn_ref : string option;
      result : (Wire_keeper_context.keeper_tool_calls_page, http_error) result;
    }
  | Reply_keeper_tool_result of {
      keeper : string;
      execution_id : string;
      result : (Wire_keeper_context.tool_result_response, http_error) result;
    }
  | Reply_keeper_turn_flow of {
      keeper : string;
      turn_ref : string;
      result : (Wire_keeper_context.turn_flow, http_error) result;
    }
  | Reply_keeper_checkpoints of {
      keeper : string;
      result :
        (Wire_keeper_context.keeper_checkpoints_inventory, http_error) result;
    }
  | Reply_keeper_checkpoint_purge of {
      keeper : string;
      result : (Wire_keeper_context.checkpoint_purge_result, http_error) result;
    }
  | Reply_keeper_checkpoint_delete of {
      keeper : string;
      result : (Wire_keeper_context.checkpoint_delete_result, http_error) result;
    }
  | Reply_keeper_operator_note_loaded of {
      keeper : string;
      result : (Wire_keeper_context.keeper_operator_note, http_error) result;
    }
  | Reply_keeper_operator_note_saved of {
      keeper : string;
      result : (Wire_keeper_context.keeper_operator_note, http_error) result;
    }
  | Reply_keeper_control of {
      keeper : string;
      label : Say.t;
      refresh_roster : bool;
      result : (unit, http_error) result;
    }
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
  | Reply_setup_login_interrupted of { login_id : string; error : http_error }
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
  | Reply_runtime_lane_mutation of {
      lane_id : string;
      operation : [ `Create | `Update | `Delete ];
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
  | Reply_tool_series_summary of {
      tool : string option;
      since_hours : int;
      result : (Wire_runtime.tool_series_summary, http_error) result;
    }
  | Reply_tools_dashboard of {
      keeper : string option;
      result : (Wire_runtime.tools_dashboard_snapshot, http_error) result;
    }
  | Reply_tools_catalog of (Wire_runtime.tools_catalog, http_error) result
  | Reply_skills of (Wire_runtime.skills_snapshot, http_error) result
  | Reply_connectors of (Wire_runtime.connector_row list, http_error) result
  | Reply_browser_lane of
      (Wire_runtime.browser_lane_status, http_error) result
  | Reply_browser_tabs of {
      client_id : string;
      result : (Wire_runtime.browser_tabs_response, http_error) result;
    }
  | Reply_lane_addons of
      (Wire_runtime.lane_addons_snapshot, http_error) result
  | Reply_lane_addon_asks of
      (Wire_runtime.lane_addon_ask_row list, http_error) result
  | Reply_lane_addon_ask_answer of {
      declaration_id : string;
      ask_id : string;
      result : (unit, http_error) result;
    }
  | Reply_keeper_purge of {
      keeper : string;
      result : (unit, http_error) result;
    }
  | Reply_mcp_clients of (Wire_runtime.mcp_client_row list, http_error) result
  | Reply_sandboxes of (Wire_infra.sandboxes_snapshot, http_error) result
  | Reply_keeper_sandbox of {
      keeper : string;
      result : (Wire_infra.keeper_sandbox_response, http_error) result;
    }
  | Reply_repositories of (Wire_infra.repository list, http_error) result
  | Reply_repository_activity of {
      repo_id : string;
      result : (Wire_infra.repository_activity, http_error) result;
    }
  | Reply_system_logs of (Wire_infra.system_log_entry list, http_error) result
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
  | Reply_action_ack of {
      label : Say.t;
      ack_scope : ack_effect;
      for_modal : Nav.inline_action_kind option;
      result : (unit, http_error) result;
    }
  | Reply_fusion_runs_snapshot of
      (Wire_runtime.fusion_runs_snapshot, http_error) result
  | Reply_fusion_run_detail of {
      run_id : string;
      result : (Wire_runtime.fusion_run_detail, http_error) result;
    }
  | Reply_fusion_config of
      (Wire_runtime.fusion_config_options, http_error) result
  | Reply_fusion_board_evidence of {
      post_id : string;
      result : (Wire_runtime.fusion_evidence_post, http_error) result;
    }
  | Reply_harness_health of (Wire_work.harness_health, http_error) result
  | Reply_verification_evidence of {
      verification_id : string;
      result : (Wire_work.verification_evidence_bundle, http_error) result;
    }
  | Reply_verification_summary of
      (Wire_work.verification_summary, http_error) result
  | Reply_verification_specs of
      (Wire_work.verification_specs, http_error) result
  | Reply_verification_tlc_results of
      (Wire_work.verification_tlc_results, http_error) result
  | Reply_activity_events of
      (Wire_infra.activity_event_item list * int, http_error) result
  | Reply_keeper_runtime_trace of {
      keeper : string;
      result : (Wire_infra.runtime_trace_snapshot, http_error) result;
    }
  | Reply_keeper_metrics of {
      keeper : string;
      result : (Wire_keeper_context.keeper_metrics_snapshot, http_error) result;
    }
  | Reply_keeper_sandbox_logs of {
      keeper : string;
      result : (Wire_keeper_context.keeper_sandbox_logs, http_error) result;
    }
  | Reply_workspace_children of {
      scope : Wire_infra.workspace_scope;
      dir : string;
      result : (Wire_infra.workspace_tree_node list, http_error) result;
    }
  | Reply_workspace_files of {
      scope : Wire_infra.workspace_scope;
      result : (Wire_infra.workspace_files_catalog, http_error) result;
    }
  | Reply_workspace_search of {
      scope : Wire_infra.workspace_scope;
      result : (Wire_infra.workspace_search_result, http_error) result;
    }
  | Reply_workspace_file of {
      scope : Wire_infra.workspace_scope;
      path : string;
      result : (Wire_infra.workspace_file_content, http_error) result;
    }
  | Reply_git_branches of {
      scope : Wire_infra.workspace_scope;
      result : (Wire_infra.git_branch_entry list, http_error) result;
    }
  | Reply_git_worktrees of {
      scope : Wire_infra.workspace_scope;
      result : (Wire_infra.git_worktree_entry list, http_error) result;
    }
  | Reply_git_status of {
      scope : Wire_infra.workspace_scope;
      result : (Wire_infra.git_status_snapshot, http_error) result;
    }
  | Reply_git_blame of {
      scope : Wire_infra.workspace_scope;
      path : string;
      result : (Wire_infra.git_blame_entry list, http_error) result;
    }
  | Reply_git_log of {
      scope : Wire_infra.workspace_scope;
      path : string;
      result : (Wire_infra.git_log_commit list, http_error) result;
    }
  | Reply_git_diff of {
      scope : Wire_infra.workspace_scope;
      path : string;
      result : (Wire_infra.git_diff_snapshot, http_error) result;
    }
  | Reply_memory_health_keeper of {
      keeper : string;
      result :
        (Wire_knowledge.keeper_memory_health_row option, http_error) result;
    }
  | Reply_workspace_memory_ledger of
      (Wire_knowledge.workspace_memory_ledger, http_error) result
  | Reply_workspace_memory_context of
      (Wire_knowledge.workspace_memory_context, http_error) result
  | Reply_keeper_memory_journal of {
      keeper : string;
      result : (Wire_knowledge.keeper_memory_journal, http_error) result;
    }
  | Reply_oauth_providers of
      (Wire_keeper_context.oauth_providers_snapshot, http_error) result
  | Reply_oauth_attached_tools of {
      keeper : string;
      result :
        (Wire_keeper_context.oauth_attached_tools_snapshot, http_error) result;
    }
  | Reply_oauth_attempt_status of {
      keeper : string;
      provider : string;
      attempt_id : string;
      result : (Wire_keeper_context.oauth_attempt_status, http_error) result;
    }
  | Reply_oauth_login of {
      keeper : string;
      result : (Wire_keeper_context.oauth_login_result, http_error) result;
    }
  | Reply_oauth_mutation of {
      keeper : string;
      label : Say.t;
      result : (unit, http_error) result;
    }
  | Reply_board_quarantines of {
      keeper : string; generation : int; result : (Board_quarantine.inventory, http_error) result;
    }
  | Reply_board_recovery of {
      item : Board_quarantine.inventory_item;
      result : (Board_quarantine.recovery_receipt, http_error) result;
    }
  | Reply_github_identity of {
      keeper : string;
      result :
        (Wire_keeper_context.github_identity_observation, http_error) result;
    }
  | Reply_github_token_save of {
      keeper : string;
      result :
        (Wire_keeper_context.github_identity_observation, http_error) result;
    }
  | Reply_addon_package_catalog of
      (Wire_runtime.addon_package_catalog, http_error) result
  | Reply_addon_package_preview of {
      manifest_path : string;
      result : (Wire_runtime.addon_package_preview, http_error) result;
    }
  | Reply_connector_names of {
      connector : string;
      result : (Wire_runtime.connector_names_page, http_error) result;
    }
  | Reply_gate_snapshot of (Wire_work.gate_snapshot, http_error) result
  | Reply_tool_approval_modes of
      (Wire_work.tool_approval_modes_snapshot, http_error) result
  | Reply_late_approval_attempts of
      (Wire_work.late_approval_attempt list, http_error) result
  | Reply_gate_tool_events of
      (Wire_work.gate_tool_events_snapshot, http_error) result
  | Reply_tool_quality of (Wire_runtime.tool_quality_snapshot, http_error) result
  | Reply_keeper_waiting_inventory of {
      keeper : string;
      result : (Wire_runtime.keeper_waiting_inventory, http_error) result;
    }
  | Reply_mcp_tools_list of
      (Wire_runtime.mcp_tool_schema_entry list, http_error) result
  | Reply_mcp_tools_call of {
      tool_name : string;
      result : (Wire_runtime.mcp_tool_call_result, http_error) result;
    }
  | Reply_gate_mutation of {
      label : Say.t;
      refresh_gate : bool;
      refresh_modes : bool;
      refresh_late : bool;
      result : (unit, http_error) result;
    }

let chat_status_reply ~keeper ~operation_id ~requested_at result =
  match result with
  | Error (Http_error { status; body; _ })
    when Wire_fleet.is_absent_operation_error ~keeper ~operation_id ~status ~body ->
      Reply_chat_absence { keeper; operation_id; requested_at }
  | Ok _ | Error (Http_error _ | Transport _ | Decode_error _ | Workspace_mismatch _) ->
      Reply_chat_status { keeper; operation_id; requested_at; result }

type sse_event =
  | Sse_observer_handshake of Wire_observer.handshake_result
  | Sse_observer_delivery of Wire_observer.delivery
  | Sse_fleet of Wire_fleet.fleet_stream_event
  | Sse_log_frame of Wire_infra.system_log_frame
  | Sse_models_metrics_snapshot of Wire_runtime.models_metrics_snapshot
  | Sse_tool_series of Wire_runtime.tool_series

type voice_event =
  | Voice_started
  | Voice_level of float
  | Voice_transcribing
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
  | Memory_diagram_rendered of {
      epoch : Epoch.t;
      request_id : int;
      keeper : string;
      event_identity : string;
      kind : Knowledge_store.memory_diagram_kind;
      mode : Knowledge_store.memory_diagram_mode;
      result : (Knowledge_store.memory_diagram_payload, string) result;
    }
  | Voice_event of voice_event
  | Stream_gap of int
  | Github_login_chunk of { epoch : Epoch.t; keeper : string; text : string }
  | Github_login_done of {
      epoch : Epoch.t;
      keeper : string;
      observation : Wire_keeper_context.github_identity_observation option;
      error : string option;
    }
  | Setup_login_output of {
      epoch : Epoch.t;
      text : string;
      auth_url : string option;
      device_code : string option;
    }
  | Setup_login_input_ready of {
      epoch : Epoch.t;
      login_id : string option;
    }
