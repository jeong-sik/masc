open Alcotest

let test_is_success_http_status_called () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"Masc.Tui_decode.is_success_http_status"
  in
  if n < 1 then
    failf
      "bin/masc_tui_http.ml must call Masc.Tui_decode.is_success_http_status for raw body responses; got %d"
      n
;;

let test_http_get_uses_auth_headers () =
  let n =
    Ast_grep.count_calls
      ~module_path:"bin/masc_tui_http.ml"
      ~callee:"auth_headers"
  in
  if n < 3 then
    failf
      "bin/masc_tui_http.ml must call auth_headers >= 3; got %d"
      n
;;

let test_http_client_does_not_own_tui_env_contract () =
  let module_path = "bin/masc_tui_http.ml" in
  check int "no local TUI env literals" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_TUI_");
  check int "no ambient agent env fallback" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"MASC_AGENT");
  check int "no local timeout env accessor" 0
    (Ast_grep.count_calls ~module_path ~callee:"Env_config_core.get_float_nonneg");
  check int "no local timeout env binding" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"timeout_env")
;;

let test_keeper_chat_uses_current_async_contract () =
  let module_path = "bin/masc_tui.ml" in
  check int "TUI keeper chat has no removed models field" 0
    (Ast_grep.count_string_literals ~module_path ~needle:"models");
  check int "TUI targets the keeper chat stream once" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_http.ml"
       ~needle:"/api/v1/keepers/chat/stream");
  check int "request projection owns the required request id field" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_keeper_chat_projection.ml"
       ~needle:"request_id");
  check int "blocking send helper is gone" 0
    (Ast_grep.count_value_bindings ~module_path ~name:"send_keeper_message");
  check int "permissive whole-body decoder is not used by the TUI" 0
    (Ast_grep.count_calls_across_files
       ~module_paths:[ "bin/masc_tui.ml"; "bin/masc_tui_http.ml" ]
       ~callee:"Tui_decode.parse_keeper_chat_response");
  check bool "chat POST has a finite request deadline" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_http_client.post_sync" ~label:"timeout_sec"
     >= 1);
  check int "chat send does not keep the root switch alive on exit" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_request" ~callee:"Eio.Fiber.fork");
  check bool "chat send runs in a cancellable daemon fiber" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_request" ~callee:"Eio.Fiber.fork_daemon"
     >= 1);
  check bool "async completion checks request identity" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"Keeper_chat.same_request_identity"
     >= 1);
  check int "same-ID reconnect never mints a fresh request" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message"
       ~callee:"Keeper_chat.create_request");
  check int "prepared retry never recreates a missing recovery fence" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message"
       ~callee:"Keeper_chat_recovery.persist_pending");
  check bool "recovery errors can reload durable state" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message"
       ~callee:"Keeper_chat_recovery.load_pending"
     >= 1);
  check bool "prepared retry dispatches only after its persistence branch" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message" ~callee:"launch_keeper_request"
     >= 1);
  check bool "prepared replay preserves prior outcome uncertainty" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message" ~callee:"remember_unverified"
     >= 1);
  check bool "prepared replay deduplicates the user history row" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message" ~callee:"append_user_history_once"
     >= 1);
  check bool "draft cleanup checks Keeper and message identity" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"consume_dispatched_message_draft" ~callee:"String.equal"
     >= 3);
  check bool "settled cleanup retry uses durable fence removal" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message"
       ~callee:"launch_keeper_cleanup"
     >= 1);
  check bool "cleanup retry holds the cross-process dispatch lock" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_cleanup"
       ~callee:"Keeper_chat_recovery.with_dispatch_lock"
     >= 1);
  check bool "cleanup retry removes only the exact durable fence" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_cleanup"
       ~callee:"Keeper_chat_recovery.clear_pending"
     >= 1);
  check int "settled cleanup helper never POSTs" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"clear_keeper_chat_recovery"
       ~callee:"launch_keeper_request");
  check int "settled cleanup helper never GETs" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"clear_keeper_chat_recovery"
       ~callee:"launch_keeper_reconciliation");
  check bool "chat POST owns a cross-process dispatch claim" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_request"
       ~callee:"Keeper_chat_recovery.with_dispatch_claim"
     >= 1);
  check bool "dispatch lock waits for main-state acknowledgement" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"enqueue_dispatch_ack" ~callee:"Eio.Promise.await"
     >= 1);
  check int "cleanup retry issues no chat POST" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_cleanup"
       ~callee:"Masc_tui_http.post_keeper_chat");
  check int "cleanup retry issues no operation GET" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_cleanup"
       ~callee:"Masc_tui_http.fetch_keeper_chat_operation");
  check bool "same-ID recovery uses exact operation reconciliation" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"retry_keeper_message"
       ~callee:"launch_keeper_reconciliation"
     >= 1);
  check int "same-ID recovery never re-POSTs the chat request" 0
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_reconciliation"
       ~callee:"Masc_tui_http.post_keeper_chat");
  check bool "request is durably fenced before POST" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"start_keeper_message"
       ~callee:"Keeper_chat_recovery.persist_pending"
     >= 1);
  check bool "startup restores the durable request fence" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"Keeper_chat_recovery.load_pending"
     >= 1);
  check bool "startup routes prepared and accepted phases explicitly" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"Keeper_chat_recovery.resume_pending"
     >= 1);
  check bool "accepted interrupted streams persist their recovery phase" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"mark_keeper_chat_accepted"
     >= 1);
  check bool "verified rejection persists a no-dispatch terminal phase" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"mark_keeper_chat_rejected"
     >= 1);
  check bool "unverified outcome durably gates exact-ID replay" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"mark_keeper_chat_replayable"
     >= 1);
  check bool "result handling consumes decoder acceptance provenance" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"apply_keeper_chat_result"
       ~callee:"Keeper_chat.error_acceptance_observed"
     >= 1);
  check bool "HTTP projection preserves stream acceptance provenance" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_http.ml"
       ~binding_name:"post_keeper_chat"
       ~callee:"Masc_tui_keeper_chat_projection.decode_response_with_provenance"
     >= 1);
  check bool "recovery polls the exact durable operation" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"launch_keeper_reconciliation"
       ~callee:"Masc_tui_http.fetch_keeper_chat_operation"
     >= 1);
  let render_path = "bin/masc_tui_render.ml" in
  List.iter
    (fun callee ->
      check bool ("message renderer wires " ^ callee) true
        (Ast_grep.count_calls_in_value_binding ~module_path:render_path
           ~binding_name:"render_keeper_message" ~callee
         >= 1))
    (* [Ansi.move_to] is gone from this binding on purpose: the renderer no
       longer writes a cursor escape inline. It hands the position to
       [finish_frame ~cursor:(Frame_presenter.Visible_at ...)], and the frame
       presenter emits the move when it paints. Asserting the old escape here
       would pin the pre-differential-frame renderer. *)
    [ "Message_layout.input_viewport"
    ; "Message_layout.input_cursor_row"
    ; "Message_layout.input_cursor_column"
    ; "Message_layout.message_viewport_supported"
    ; "finish_frame"
    ];
  check bool "message input uses the same viewport gate as rendering" true
    (Ast_grep.count_calls_in_value_binding ~module_path
       ~binding_name:"keeper_message_input_supported"
       ~callee:"Masc_tui_message_layout.message_viewport_supported"
     >= 1);
  check bool "main loop suppresses unsupported message input" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"keeper_message_input_supported"
     >= 1);
  check bool "compact viewport still recognizes recovery control input" true
    (Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:"main"
       ~callee:"Char.code"
     >= 1)
;;

let test_operator_approvals_use_current_contract () =
  check int "operator summary endpoint is exact" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_http.ml"
       ~needle:
         "/api/v1/operator?view=summary&include_messages=0&include_keepers=0");
  check bool "loader uses exact operator projection" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Masc_tui_operator_projection.decode_snapshot"
     >= 1);
  check bool "semantic action status is checked" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
     >= 1);
  check bool "submitted token is bound into response validation" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
       ~label:"expected_token"
     >= 1);
  check bool "submitted decision is bound into response validation" true
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_http.ml"
       ~callee:"Masc_tui_operator_projection.decode_confirm_response"
       ~label:"expected_decision"
     >= 1);
  check bool "HTTP refresh and action reconciliation reload approvals" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"load_approvals"
     >= 2);
  check bool "refreshes reserve an approval generation" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.reserve_refresh"
     >= 1);
  check bool "actions invalidate older approval generations" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.begin_action"
     >= 1);
  check bool "only the owning action completion clears inflight state" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.Flow.finish_action"
     >= 1);
  check bool "approval input uses the behavior-tested two-key gate" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"Approval.approval_gate_transition"
     >= 1);
  check int "approval refresh preserves selected token identity" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"apply_approvals_load"
       ~callee:"Approval.reconcile_cursor");
  check int "deferred confirmation has truthful operator copy" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation accepted; action deferred: %s");
  check int "execution failure preserves accepted confirmation" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation accepted; action failed: %s");
  check int "transport failure remains unverified" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui.ml"
       ~needle:"Confirmation outcome unverified");
  check int "payload has its own visible row" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_render.ml"
       ~needle:"  %spayload=%s%s");
  check bool "approval renderer sanitizes direct external text" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.single_line"
     >= 7);
  check int "approval renderer sanitizes optional text with defaults" 3
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.single_line_or");
  check int "approval renderer sanitizes optional error text" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Terminal_text.optional_single_line");
  check int "terminal text boundary delegates to the typed sanitizer" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_ansi.ml"
       ~binding_name:"single_line"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "approval payload uses its terminal projection" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:
         "Masc_tui_operator_projection.approval_payload_for_terminal");
  check int "approval payload projection serializes once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_operator_projection.ml"
       ~binding_name:"approval_payload_for_terminal"
       ~callee:"Yojson.Safe.to_string");
  check int "approval payload projection sanitizes once" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_operator_projection.ml"
       ~binding_name:"approval_payload_for_terminal"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "approval renderer never serializes a raw payload" 0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_approvals"
       ~callee:"Yojson.Safe.to_string");
  check int "dashboard event text crosses the terminal boundary" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_dashboard"
       ~callee:"Terminal_text.single_line");
  check int "overview event text crosses the terminal boundary" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_overview"
       ~callee:"Terminal_text.single_line");
  check int "briefing is not an approval source" 0
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"pending_confirms")
;;

let test_planning_constructors_do_not_collide () =
  let module_path = "bin/masc_tui_types.ml" in
  let planning_mode_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"planning_mode"
  in
  let surface_constructors =
    Ast_grep.constructor_names_of_type ~module_path ~type_name:"surface"
  in
  check bool "planning sub-mode does not reuse top-level Planning" false
    (List.mem "Planning" planning_mode_constructors);
  check bool "planning list sub-mode explicit" true
    (List.mem "Planning_list" planning_mode_constructors);
  check bool "planning detail sub-mode explicit" true
    (List.mem "Planning_detail" planning_mode_constructors);
  check bool "top-level Planning surface remains" true
    (List.mem "Planning" surface_constructors)
;;

let test_planning_phase_uses_goal_ssot () =
  check bool "projection parses the canonical goal phase" true
    (Ast_grep.count_calls
       ~module_path:"lib/tui_decode.ml"
       ~callee:"Goal_phase.parse"
     >= 1);
  check bool "loader uses the behavioral planning decoder" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.decode_planning_snapshot"
     >= 1);
  check bool "renderer labels the canonical goal phase" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"Goal_phase.to_string"
     >= 1);
  check int "renderer does not lowercase planning status strings" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"String.lowercase_ascii");
  check int "projection rejects an unknown canonical phase" 1
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"unknown planning goal phase")
;;

let test_tui_current_projection_wiring () =
  check int "task loader is a named canonical-backlog projection" 1
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_loader.ml"
       ~name:"load_active_tasks");
  check bool "task loader uses the canonical backlog observation" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Workspace_backlog.read_backlog_observation_with_source_r"
     >= 1);
  check bool "loader uses the behavior-tested active task projection" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.active_tasks_of_domain"
     >= 1);
  check int "task row projection has one domain boundary" 1
    (Ast_grep.count_value_bindings
       ~module_path:"lib/tui_decode.ml"
       ~name:"task_of_domain");
  check bool "keeper loader uses canonical persisted-name classification" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Keeper_meta_store.persisted_keeper_names_result"
     >= 1);
  check bool "keeper loader uses the typed current-schema store" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Keeper_meta_store.read_meta"
     >= 1);
  check bool "keeper loader projects typed metadata" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Tui_decode.keeper_of_meta"
     >= 1);
  check bool "keeper metrics use the cluster-aware canonical path" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_selected_keeper_logs"
       ~callee:"Keeper_types_support.keeper_metrics_store"
     = 1);
  check bool "keeper metrics use the strict bounded physical tail" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_metrics_tail.ml" ~binding_name:"load"
       ~callee:"Dated_jsonl.read_recent_result"
     = 1);
  check int "selected Keeper identity reaches the metrics decoder" 1
    (Ast_grep.count_calls_with_label
       ~module_path:"bin/masc_tui_loader.ml"
       ~callee:"Metrics_tail.load" ~label:"expected_keeper");
  check bool "all log interactions use the selected Keeper loader" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"load_selected_keeper_logs"
     >= 3);
  check bool "metadata refresh reconciles the selected log identity" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_from_masc_dir"
       ~callee:"Metrics_tail.reconcile_selection"
     = 1);
  check bool "metrics diagnostics are terminal-safe before rendering" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Keeper_chat.terminal_safe_text"
     >= 1);
  check bool "log input uses viewport-bounded scrolling" true
    (Ast_grep.count_calls_across_files
       ~module_paths:[ "bin/masc_tui.ml" ]
       ~callee:"Metrics_tail.scroll_up"
     = 1
     && Ast_grep.count_calls_across_files
          ~module_paths:[ "bin/masc_tui.ml" ]
          ~callee:"Metrics_tail.scroll_down"
        = 1);
  List.iter
    (fun retired ->
      check int ("retired raw metrics helper absent: " ^ retired) 0
        (Ast_grep.count_value_bindings
           ~module_path:"bin/masc_tui_loader.ml" ~name:retired))
    [ "read_last_lines"; "parse_log_entry"; "find_metrics_files"; "load_keeper_logs" ];
  check bool "Keeper log rows use the current typed discriminator" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/tui_decode.ml" ~binding_name:"decode_log_entry"
       ~callee:"Keeper_metrics_record.kind_of_json"
     = 1);
  check bool "live context uses the trace-scoped TurnRecord projection" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_context_state.ml" ~binding_name:"load"
       ~callee:"Projection.context_fields"
     = 1);
  check bool "loader applies the behavior-tested selection transition" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml"
       ~binding_name:"load_selected_live_context"
       ~callee:"Context_state.for_selection"
     = 1);
  check bool "log diagnostics remain operator-visible" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Metrics_tail.error_to_string"
     = 1);
  check bool "log empty copy distinguishes typed outcomes" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_logs"
       ~callee:"Metrics_tail.empty_message"
     = 1);
  check int "retired planning running alias absent" 0
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"running");
  check int "verify appears only inside verifying_count" 1
    (Ast_grep.count_string_literals
       ~module_path:"lib/tui_decode.ml"
       ~needle:"verify");
  List.iter
    (fun retired ->
       check int ("retired keeper field absent: " ^ retired) 0
         (Ast_grep.count_string_literals
            ~module_path:"lib/tui_decode.ml"
            ~needle:retired))
    [ "active_goal_ids"
    ; "active_model"
    ; "models"
    ; "proactive_enabled"
    ; "initiative_enabled"
    ; "trigger_mode"
    ; "context_budget"
    ; "drift_enabled"
    ]
;;

let test_overview_state_domains_are_closed_sum () =
  let workspace_health_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"workspace_health"
  in
  let attention_severity_constructors =
    Ast_grep.constructor_names_of_type
      ~module_path:"bin/masc_tui_types.ml"
      ~type_name:"attention_severity"
  in
  check (list string) "workspace health constructors"
    [
      "Workspace_health_critical";
      "Workspace_health_bad";
      "Workspace_health_risk";
      "Workspace_health_warning";
      "Workspace_health_degraded";
      "Workspace_health_initializing";
      "Workspace_health_ok";
      "Workspace_health_unknown";
    ]
    workspace_health_constructors;
  check (list string) "attention severity constructors"
    [
      "Attention_critical";
      "Attention_bad";
      "Attention_warning";
      "Attention_info";
    ]
    attention_severity_constructors;
  check int "loader has an explicit unknown health decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown workspace health");
  check int "loader has an explicit unknown severity decode error" 1
    (Ast_grep.count_string_literals
       ~module_path:"bin/masc_tui_loader.ml"
       ~needle:"unknown attention severity")
;;

let test_planning_cursor_uses_visible_goal_order () =
  check int "visible planning helper lives in shared types" 1
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"planning_visible_goals");
  check int "visible planning helper avoids duplicate-prone insertion helper" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_types.ml"
       ~name:"insert_sorted");
  check bool "visible planning helper uses stable depth sort" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_types.ml"
       ~callee:"List.stable_sort"
     >= 1);
  check int "render no longer owns a private tree sorter" 0
    (Ast_grep.count_value_bindings
       ~module_path:"bin/masc_tui_render.ml"
       ~name:"sort_goals_for_tree");
  check bool "render uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml"
       ~callee:"planning_visible_goals"
     >= 1);
  check bool "key handling uses shared visible-goal order" true
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui.ml"
       ~callee:"planning_visible_goals"
     >= 2)
;;

let test_render_loop_uses_monotonic_dirty_schedule () =
  let main_path = "bin/masc_tui.ml" in
  check bool "main loop reads a monotonic clock" true
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Mtime_clock.elapsed_ns"
     >= 3);
  check int "main loop has no wall-clock refresh deadline" 0
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Unix.gettimeofday");
  check bool "context bar width is total" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_ansi.ml"
       ~binding_name:"ctx_bar"
       ~callee:"Masc_tui_render_schedule.nonnegative_width"
     = 1);
  check bool "keeper detail clamps its derived bar width" true
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml"
       ~binding_name:"render_keeper_detail"
       ~callee:"Masc_tui_render_schedule.keeper_context_bar_width"
     = 1);
  check bool "interrupted input uses the deadline-aware retry contract" true
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"read_byte_unix"
       ~callee:"Render_schedule.Input_wait.await"
     = 1);
  check int "surface renderers perform no direct stdout writes" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml" ~callee:"print_string");
  check int "surface renderers perform no direct flushes" 0
    (Ast_grep.count_calls
       ~module_path:"bin/masc_tui_render.ml" ~callee:"flush");
  check int "main has one frame presentation boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"Frame_presenter.present");
  check int "main gates input once on the compact viewport" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main"
       ~callee:"Render_schedule.Viewport.requires_compact_frame");
  check int "render owns one compact viewport gate" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"Render_schedule.Viewport.requires_compact_frame");
  check int "compact render has one fallback branch" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"render_terminal_too_small");
  check int "compact render has one normal-surface branch" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_render.ml" ~binding_name:"render"
       ~callee:"render_surface");
  check int "resize invalidation and Force request share one boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Frame_presenter.invalidate");
  check int "resize boundary owns terminal-size cache invalidation" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"invalidate_terminal_size");
  check int "resize boundary requests one forced frame" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Render_schedule.request");
  check int "resize request's reason is exactly Force" 1
    (Ast_grep
     .count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"invalidate_frame_for_resize"
       ~callee:"Render_schedule.request" ~position:1
       ~constructor:"Render_schedule.Force");
  check int "main uses the coupled resize boundary" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"main" ~callee:"invalidate_frame_for_resize");
  check int "presentation consumes the external-write marker as invalidation" 1
    (Ast_grep
     .count_applications_with_exact_labelled_unit_call_in_value_binding
       ~module_path:main_path ~binding_name:"main"
       ~callee:"Frame_presenter.present" ~label:"invalidate_before"
       ~nested_callee:"consume_terminal_write_outside_frame");
  check int "TTY gate validates stdin and stdout" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"require_interactive_terminal" ~callee:"Unix.isatty");
  check int "loader marks its direct diagnostic write" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml" ~binding_name:"report"
       ~callee:"Masc_tui_ansi.note_terminal_write_outside_frame");
  let signal_handler signal handler =
    Ast_grep.count_applications_with_exact_signal_handler_in_value_binding
      ~module_path:main_path ~binding_name:"enter_terminal_session" ~signal
      ~handler
  in
  check bool "startup registers cleanup and handlers before raw mode" true
    (Ast_grep.direct_call_sequence_matches_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callees:
         [ "at_exit"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Sys.set_signal"
         ; "Unix.tcsetattr"
         ]);
  check int "startup registers the real cleanup callback" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callee:"at_exit" ~position:0 ~identifier:"cleanup");
  check int "main enters the guarded terminal session once" 1
    (Ast_grep
     .count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"main"
       ~callee:"enter_terminal_session"
       ~arguments:
         [ "cleanup", "cleanup"
         ; "terminate", "terminate"
         ; "request_full_repaint", "request_full_repaint"
         ; "suspend", "suspend"
         ; "new_term", "new_term"
         ]);
  check int "SIGINT terminates through cleanup" 1
    (signal_handler "Sys.sigint" "terminate");
  check int "SIGTERM terminates through cleanup" 1
    (signal_handler "Sys.sigterm" "terminate");
  check int "SIGHUP terminates through cleanup" 1
    (signal_handler "Sys.sighup" "terminate");
  check int "SIGQUIT terminates through cleanup" 1
    (signal_handler "Sys.sigquit" "terminate");
  check int "SIGWINCH requests a full repaint" 1
    (signal_handler "Sys.sigwinch" "request_full_repaint");
  check int "SIGCONT requests a full repaint" 1
    (signal_handler "Sys.sigcont" "request_full_repaint");
  check int "SIGTSTP initially installs the suspend handler" 1
    (signal_handler "Sys.sigtstp" "suspend");
  check int "resume reinstalls the suspend handler" 1
    (Ast_grep.count_applications_with_exact_signal_handler_in_value_binding
       ~module_path:main_path ~binding_name:"suspend" ~signal:"Sys.sigtstp"
       ~handler:"suspend");
  check int "startup raw mode uses new termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"enter_terminal_session"
       ~callee:"Unix.tcsetattr" ~position:2 ~identifier:"new_term");
  check int "terminal restoration cleans presenter state" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"restore_terminal" ~callee:"Frame_presenter.cleanup");
  check int "terminal restoration reapplies old termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"restore_terminal"
       ~callee:"Unix.tcsetattr" ~position:2 ~identifier:"old_term");
  check int "suspend restores the shell terminal first" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"suspend" ~callee:"restore_terminal");
  check int "suspend temporarily installs the default action" 1
    (Ast_grep
     .count_applications_with_exact_identifier_and_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callee:"Sys.set_signal" ~identifier_position:0
       ~identifier:"Sys.sigtstp" ~constructor_position:1
       ~constructor:"Sys.Signal_default");
  check int "suspend self-signals SIGTSTP" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"suspend" ~callee:"Unix.kill"
       ~position:1 ~identifier:"Sys.sigtstp");
  check int "resume reapplies raw termios" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callee:"Unix.tcsetattr" ~position:2 ~identifier:"new_term");
  check int "resume requests a repaint" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:main_path
       ~binding_name:"suspend" ~callee:"request_full_repaint");
  check bool "suspend reaches self-stop only after terminal restoration" true
    (Ast_grep.direct_call_sequence_matches_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~callees:[ "restore_terminal"; "Sys.set_signal"; "Fun.protect" ]);
  check bool "resume lifecycle is confined to Fun.protect finally" true
    (Ast_grep.fun_protect_sequences_match_in_value_binding
       ~module_path:main_path ~binding_name:"suspend"
       ~body_callees:[ "Unix.kill" ]
       ~finally_callees:
         [ "Sys.set_signal"; "Unix.tcsetattr"; "request_full_repaint" ]);
  check int "the local input loop propagates one Break" 1
    (Ast_grep.count_applications_with_exact_positional_constructor_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop" ~callee:"raise"
       ~position:0 ~constructor:"Break");
  check bool "Break is converted to success outside the root Eio switch" true
    (Ast_grep.try_handler_wraps_nested_callback_in_value_binding
       ~module_path:main_path ~binding_name:"run_with_eio_context"
       ~exception_constructor:"Break" ~outer_callee:"Eio_main.run"
       ~inner_callee:"Eio.Switch.run" ~callback_callee:"f");
  check int "main passes its message mode to q classification" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop"
       ~callee:"Render_schedule.Input_shortcut.is_quit"
       ~arguments:[ "message_mode", "message_mode" ]);
  check int "main passes its message mode to Keeper classification" 1
    (Ast_grep.count_applications_with_exact_labelled_identifiers_in_value_binding
       ~module_path:main_path ~binding_name:"run_loop"
       ~callee:"Render_schedule.Input_shortcut.opens_keepers"
       ~arguments:[ "message_mode", "message_mode" ])
;;

let test_renderers_sanitize_untrusted_terminal_fields () =
  let render_path = "bin/masc_tui_render.ml" in
  let sanitizer_calls =
    [ "Terminal_text.single_line"
    ; "Terminal_text.optional_single_line"
    ; "Terminal_text.single_line_or"
    ; "Terminal_text.single_lines"
    ; "Terminal_text.short_timestamp"
    ; "Terminal_text.clock_timestamp"
    ]
  in
  let fixture_path = "test/fixtures/tui_terminal_text_ast_fixture.ml" in
  check int "field boundary helper catches the unwrapped fixture field" 1
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:fixture_path ~binding_name:"render"
       ~callees:sanitizer_calls ~fields:[ "safe"; "raw" ]);
  check int "identifier boundary helper catches the unwrapped fixture value" 1
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:fixture_path ~binding_name:"report"
       ~callees:[ "Terminal_text.single_line" ]
       ~identifiers:[ "path"; "err" ]);
  let check_binding module_path binding =
    check int (binding ^ " exists exactly once") 1
      (Ast_grep.count_value_bindings ~module_path ~name:binding)
  in
  let check_fields binding fields =
    check_binding render_path binding;
    List.iter
      (fun field ->
        let total =
          Ast_grep.count_field_accesses_outside_calls_in_value_binding
            ~module_path:render_path ~binding_name:binding ~callees:[]
            ~fields:[ field ]
        in
        if total = 0 then
          failf "%s no longer accesses expected untrusted field %s" binding field;
        let outside =
          Ast_grep.count_field_accesses_outside_calls_in_value_binding
            ~module_path:render_path ~binding_name:binding
            ~callees:sanitizer_calls ~fields:[ field ]
        in
        if outside <> 0 then
          failf
            "%s has %d %s access(es) outside Terminal_text"
            binding outside field)
      fields
  in
  let check_identifiers ~module_path ~binding ~callees identifiers =
    check_binding module_path binding;
    List.iter
      (fun identifier ->
        let total =
          Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path ~binding_name:binding ~callees:[]
            ~identifiers:[ identifier ]
        in
        if total = 0 then
          failf "%s no longer references expected untrusted value %s" binding
            identifier;
        let outside =
          Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path ~binding_name:binding ~callees
            ~identifiers:[ identifier ]
        in
        if outside <> 0 then
          failf "%s has %d raw %s reference(s) outside Terminal_text" binding
            outside identifier)
      identifiers
  in
  check_fields "task_line" [ "id"; "title" ];
  check_identifiers ~module_path:render_path ~binding:"task_line"
    ~callees:sanitizer_calls [ "name" ];
  check_fields "render_dashboard" [ "workspace"; "name"; "status"; "content" ];
  check_fields "render_overview"
    [ "workspace"
    ; "overview_error"
    ; "ov_cluster"
    ; "ov_project"
    ; "ai_summary"
    ; "content"
    ; "tasks_error"
    ];
  check_fields "render_approvals"
    [ "aps_actor_filter"
    ; "approvals_error"
    ; "ap_target_id"
    ; "ap_actor"
    ; "ap_action_type"
    ; "ap_target_type"
    ; "ap_summary"
    ; "ap_expires_at"
    ; "ap_payload"
    ; "ap_trace_id"
    ; "ap_created_at"
    ];
  check_fields "render_board_list"
    [ "board_error"; "bp_id"; "bp_author"; "bp_title" ];
  check_fields "render_board_read"
    [ "bp_id"
    ; "bp_author"
    ; "bp_title"
    ; "bp_created_at"
    ; "bp_body"
    ; "bc_author"
    ; "bc_content"
    ];
  check_fields "render_planning_list"
    [ "planning_error"; "pg_due_date"; "pg_title" ];
  check_fields "render_planning_detail"
    [ "pg_id"; "pg_title"; "pg_due_date"; "pg_metric"; "pg_target_value" ];
  check_fields "render_keeper_list"
    [ "keepers_error"; "k_current_task_id"; "k_name" ];
  check_fields "render_keeper_detail"
    [ "k_name"
    ; "k_current_task_id"
    ; "live_context_error"
    ; "observed_at"
    ; "turn_ref"
    ; "k_last_turn_ts"
    ; "k_created_at"
    ; "k_updated_at"
    ];
  check_fields "render_keeper_logs"
    [ "k_name"; "le_ts"; "le_tools_used"; "le_work_kind" ];
  let ansi_path = "bin/masc_tui_ansi.ml" in
  [ "single_line"
  ; "optional_single_line"
  ; "single_line_or"
  ; "single_lines"
  ; "short_timestamp"
  ; "clock_timestamp"
  ]
  |> List.iter (check_binding ansi_path);
  check int "shared terminal boundary delegates to the typed sanitizer" 1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:ansi_path ~binding_name:"single_line"
       ~callee:"Masc.Tui_decode.sanitize_terminal_text");
  check int "optional boundary maps the sanitizer" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:ansi_path ~binding_name:"optional_single_line"
       ~callee:"Option.map" ~position:0 ~identifier:"single_line");
  check int "defaulted boundary uses the optional sanitizer" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"single_line_or" ~callee:"optional_single_line");
  check int "list boundary maps the sanitizer" 1
    (Ast_grep
     .count_applications_with_exact_positional_identifier_in_value_binding
       ~module_path:ansi_path ~binding_name:"single_lines" ~callee:"List.map"
       ~position:0 ~identifier:"single_line");
  check int "short timestamp delegates to slice-then-sanitize helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"short_timestamp"
       ~callee:"Masc.Tui_decode.short_timestamp_for_terminal");
  check int "clock timestamp delegates to slice-then-sanitize helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:ansi_path
       ~binding_name:"clock_timestamp"
       ~callee:"Masc.Tui_decode.clock_timestamp_for_terminal");
  let decode_path = "lib/tui_decode.ml" in
  [ "short_timestamp_for_terminal"; "clock_timestamp_for_terminal" ]
  |> List.iter (fun binding ->
       check_binding decode_path binding;
       check int (binding ^ " has one final sanitizer") 1
         (Ast_grep.count_calls_in_value_binding ~module_path:decode_path
            ~binding_name:binding ~callee:"sanitize_terminal_text");
       check int (binding ^ " never uses raw text after sanitizing") 0
         (Ast_grep.count_identifiers_outside_calls_in_value_binding
            ~module_path:decode_path ~binding_name:binding
            ~callees:[ "sanitize_terminal_text" ] ~identifiers:[ "text" ]));
  check int "log renderer does not slice sanitized timestamp bytes" 0
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_logs" ~callee:"String.sub");
  check int "log renderer uses the safe clock projection once" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_logs"
       ~callee:"Terminal_text.clock_timestamp");
  check int "keeper detail uses safe short projections for every timestamp" 5
    (Ast_grep.count_calls_in_value_binding ~module_path:render_path
       ~binding_name:"render_keeper_detail"
       ~callee:"Terminal_text.short_timestamp");
  check_identifiers ~module_path:"bin/masc_tui_loader.ml" ~binding:"report"
    ~callees:[ "Masc_tui_ansi.Terminal_text.single_line" ] [ "path"; "err" ]
;;

let () =
  run "masc-tui-http-regression" [
    ( "tui-http",
      [
        test_case "check success status" `Quick test_is_success_http_status_called;
        test_case "auth headers used" `Quick test_http_get_uses_auth_headers;
        test_case
          "http client does not own TUI env contract"
          `Quick
          test_http_client_does_not_own_tui_env_contract;
        test_case
          "keeper chat uses current async contract"
          `Quick
          test_keeper_chat_uses_current_async_contract;
        test_case
          "operator approvals use current contract"
          `Quick
          test_operator_approvals_use_current_contract;
        test_case
          "planning constructors do not collide"
          `Quick
          test_planning_constructors_do_not_collide;
        test_case "planning phase uses goal SSOT" `Quick
          test_planning_phase_uses_goal_ssot;
        test_case "current projection wiring" `Quick
          test_tui_current_projection_wiring;
        test_case
          "overview state domains are closed-sum"
          `Quick
          test_overview_state_domains_are_closed_sum;
        test_case
          "planning cursor uses visible goal order"
          `Quick
          test_planning_cursor_uses_visible_goal_order;
        test_case
          "render loop uses monotonic dirty scheduling"
          `Quick
          test_render_loop_uses_monotonic_dirty_schedule;
        test_case
          "renderers sanitize untrusted terminal fields"
          `Quick
          test_renderers_sanitize_untrusted_terminal_fields;
      ]
    )
  ]
