(** Keeper_tools_oas_handler — Tool handler factory for Agent.run().

    Extracted from [Keeper_tools_oas] to break the ~1500-line module
    into smaller units.  This module contains [make_keeper_tool_handler],
    [make_tool_bundle], and [make_tools] — the closure factory and
    bundle assembly logic.

    @since P1 extraction *)

open Keeper_tools_oas
open Keeper_tools_oas_workflow
open Keeper_tools_oas_deterministic_error

let keeper_tool_call_event_json
      ~keeper_name
      ~tool_name
      ~duration_ms
      ~success
      ?error_text
      ?(extra_fields = [])
      ~ts
      ()
  =
  let fields =
    [ "type", `String "keeper_tool_call"
    ; "name", `String keeper_name
    ; "tool_name", `String tool_name
    ; "duration_ms", `Int duration_ms
    ; "success", `Bool success
    ; "ts_unix", `Float ts
    ]
  in
  let fields =
    match error_text with
    | Some error_text -> fields @ [ "error_text", `String error_text ]
    | None -> fields
  in
  `Assoc (fields @ extra_fields)
;;

let broadcast_keeper_tool_call_event
      ~keeper_name
      ~tool_name
      ~duration_ms
      ~success
      ?error_text
      ?(extra_fields = [])
      ~site
      ~ts
      ()
  =
  try
    Sse.broadcast
      (keeper_tool_call_event_json
         ~keeper_name
         ~tool_name
         ~duration_ms
         ~success
         ?error_text
         ~extra_fields
         ~ts
         ())
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_sse_broadcast_failures
      ~labels:[ "keeper", keeper_name ]
      ();
    Log.Keeper.warn
      "keeper tool-call SSE broadcast failed: keeper=%s tool=%s site=%s err=%s"
      keeper_name
      tool_name
      site
      (Printexc.to_string exn)
;;

let append_tool_exec_decision_log ~config ~keeper_name ~site entry =
  try
    Keeper_types_support.append_jsonl_line
      (Keeper_types_support.keeper_decision_log_path config keeper_name)
      entry
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_decision_audit_flush_failures
      ~labels:[ "keeper", keeper_name ]
      ();
    Log.Keeper.warn
      "keeper tool execution decision-log append failed: keeper=%s site=%s err=%s"
      keeper_name
      site
      (Printexc.to_string exn)
;;

let make_keeper_tool_handler
      ~(name : string)
      ~(input_schema : Yojson.Safe.t)
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ?turn_sandbox_factory_git
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ?on_tool_called
      ?clock
      ?(translate_input = fun j -> j)
      ~(failure_counts : failure_counts)
      ()
  : Yojson.Safe.t -> Tool_result.t
  =
  let args_key input =
    let h = Hashtbl.hash (Yojson.Safe.to_string input) in
    Printf.sprintf "%s:%d" name h
  in
  fun raw_input ->
    let t0 = Time_compat.now () in
    let input = translate_input raw_input in
    match
      Tool_input_validation.validate_args ~schema:input_schema ~name ~args:input ()
    with
    | Error validation_result ->
      let raw_result = Yojson.Safe.to_string validation_result.data in
      let output_text = normalize_tool_result ~success:false raw_result in
      let duration_ms = 0 in
      let ts = Time_compat.now () in
      let error_text = Tool_result.message validation_result in
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~success:false;
      (* RFC-0084 PR-I-3 — run_post_hooks retired.  Validation failure
         is a Handler_error from the typed-outcome perspective; emit
         the typed observers directly so metrics / usage_log still
         see it. *)
      Tool_dispatch.run_typed_post_hooks
        (Dispatch_outcome.Handler_error { exn = "validation_failed" })
        (Some validation_result);
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~success:false
        ~error_text
        ~site:"input_validation"
        ~ts
        ();
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_tools_oas_failures
        ~labels:[ "tool", name; "site", "input_validation" ]
        ();
      append_tool_exec_decision_log
        ~config
        ~keeper_name:meta.name
        ~site:"input_validation"
        (`Assoc
            [ "ts_unix", `Float ts
            ; "event", `String "tool_exec"
            ; "keeper_name", `String meta.name
            ; "tool", `String name
            ; "duration_ms", `Int duration_ms
            ; "result_bytes", `Int (String.length output_text)
            ; "ok", `Bool false
            ; "error", `String error_text
            ]);
      Tool_result.error ~tool_name:name ~start_time:t0 output_text
    | Ok input ->
      let key = args_key input in
      let prior_fails = failure_count_get failure_counts key in
      if prior_fails >= max_consecutive_failures
      then (
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_tools_oas_failures
          ~labels:[ "tool", name; "site", "blocked" ]
          ();
        Log.Keeper.warn
          "tool %s blocked after %d consecutive failures (same args)"
          name
          prior_fails;
        let msg =
          Printf.sprintf
            "This tool has failed %d times in a row with the same arguments. Try a \
             different approach or different arguments."
            prior_fails
        in
        let output_text = normalize_tool_result ~success:false msg in
        Tool_result.error ~tool_name:name ~start_time:t0 output_text)
      else (
        match
          Option.bind
            (workflow_scope_key_of_input ~tool_name:name input)
            (workflow_rejection_scope_block_get failure_counts)
        with
        | Some block ->
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_tools_oas_failures
            ~labels:[ "tool", name; "site", "workflow_scope_blocked" ]
            ();
          record_deterministic_tool_failure_metric
            ~tool_name:name
            Keeper_tool_deterministic_error.Workflow_rejection_blocked;
          Log.Keeper.warn
            "tool %s workflow rejection retry skipped for same task/action scope"
            name;
          let raw_result =
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool false
                  ; "error", `String "workflow_rejection_open_loop_blocked"
                  ; "failure_class", `String "workflow_rejection"
                  ; "recoverable", `Bool false
                  ; "error_class", `String "deterministic"
                  ])
          in
          let output_text =
            normalize_tool_result
              ~workflow_rejection_recovery_fields:
                (workflow_rejection_scope_block_fields ~tool_name:name block)
              ~success:false
              raw_result
          in
          Tool_result.error
            ~failure_class:(Some Tool_result.Workflow_rejection)
            ~tool_name:name
            ~start_time:t0
            output_text
        | None ->
          let execute_with_observers () =
          let t0 = Time_compat.now () in
          try
          let result, duration_ms =
            Inference_utils.timed (fun () ->
              Keeper_exec_tools.execute_keeper_tool_call_with_outcome
                ~config
                ~meta
                ~ctx_work:ctx_snapshot
                ?turn_sandbox_factory
                ?turn_sandbox_factory_git
                ~exec_cache
                ?search_fn
                ~name
                ~input
                ())
          in
          let raw_result = result.raw_output in
          let is_failure =
            match result.outcome with
            | `Failure -> true
            | `Success -> false
          in
          if is_failure
          then (
            let failure_class_opt =
              Keeper_exec_tools.failure_class_of_tool_result_payload raw_result
              |> tool_failure_class_of_wire_string
            in
            let is_workflow_rejection =
              match failure_class_opt with
              | Some Tool_result.Workflow_rejection -> true
              | Some (Tool_result.Transient_error | Tool_result.Policy_rejection | Tool_result.Runtime_failure)
              | None ->
                false
            in
            (* MASC/OAS Error-Warn Reduction Goal 2026-05-18, P2 reducer:
               classify deterministic policy/shape blocks so the LLM-driven
               1/3 -> 2/3 -> 3/3 retry loop short-circuits at the first
               attempt. Transient errors and shell exit-nonzero results
               are intentionally outside this surface (None branch). *)
            let deterministic_reason =
              Keeper_tool_deterministic_error.classify_raw raw_result
            in
            let workflow_rejection_recovery_fields =
              if is_workflow_rejection
              then (
                match workflow_rejection_info_of_raw raw_result with
                | Some info ->
                  let family_key = workflow_rejection_family_key ~tool_name:name info in
                  let count = workflow_rejection_count_record failure_counts family_key in
                  (match workflow_scope_key_of_input ~tool_name:name input with
                   | Some scope_key ->
                     ignore
                       (workflow_rejection_scope_block_record
                          failure_counts
                          scope_key
                          info)
                   | None -> ());
                  workflow_rejection_recovery_fields ~tool_name:name ~count raw_result
                | None -> [])
              else []
            in
            let deterministic_recovery_fields =
              match deterministic_reason with
              | None -> []
              | Some reason ->
                let key_label =
                  Keeper_tool_deterministic_error.to_telemetry_key reason
                in
                [ ( "do_not_retry_tool"
                  , `String name )
                ; ( "retry_skipped"
                  , `Bool true )
                ; ( "retry_skipped_reason"
                  , `String key_label )
                ; ( "retry_skipped_explanation"
                  , `String
                      (Keeper_tool_deterministic_error.to_string reason) )
                ]
                @ deterministic_recovery_plan_fields raw_result
            in
            let recovery_fields =
              workflow_rejection_recovery_fields @ deterministic_recovery_fields
            in
            (* Deterministic policy/shape blocks, including typed workflow
               rejections: jump the per-(tool,args) failure counter to
               [max_consecutive_failures] on the first occurrence so the next
               invocation with the same args lands in the
               [prior_fails >= max_consecutive_failures] block branch at the
               top of the handler instead of executing the same rejected tool
               again. The current call still emits once (with the
               [retry_skipped*] / workflow recovery fields above) so the LLM
               receives a single, self-correcting response. *)
            let count =
              match deterministic_reason, is_workflow_rejection with
              | Some _, _ ->
                failure_count_jump_to
                  failure_counts
                  key
                  ~target:max_consecutive_failures
              | None, true -> 0
              | None, false -> failure_count_record_failure failure_counts key
            in
            Keeper_registry.record_tool_use
              ~base_path:config.base_path
              meta.name
              ~tool_name:name
              ~success:false;
            record_keeper_internal_tool_call ~tool_name:name ~success:false ~duration_ms;
            (* Tool-call observability flows through the OAS Event_bus
             (ToolCalled + ToolCompleted). MASC-side observers removed
             in refactor/tool-call-single-source. *)
            (let tr =
               Tool_result.
                 { tool_name = name
                 ; success = false
                 ; duration_ms = Float.of_int duration_ms
                 ; data = `Null
                 ; legacy_message = raw_result
                 ; failure_class =
                     Some
                       (Option.value ~default:Tool_result.Runtime_failure failure_class_opt)
                 }
             in
             (* RFC-0084 PR-I-3 — typed observers replace
                run_post_hooks. *)
             Tool_dispatch.run_typed_post_hooks
               Dispatch_outcome.Handled (Some tr));
            let detail =
              let s = String.trim raw_result in
              String_util.utf8_safe
                ~max_bytes:(Keeper_tools_oas_markers.sse_error_preview_max_chars + 3)
                ~suffix:"..."
                s
              |> String_util.to_string
            in
            let ts = Time_compat.now () in
            broadcast_keeper_tool_call_event
              ~keeper_name:meta.name
              ~tool_name:name
              ~duration_ms
              ~success:false
              ~error_text:detail
              ~site:"error_result"
              ~ts
              ();
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_tools_oas_failures
              ~labels:[ "tool", name; "site", "error_result" ]
              ();
            (* Workflow rejections can arrive either through the
               deterministic classifier or as a raw failure_class. Normalize
               the WARN envelope so one root cause does not split across two
               operator-visible signatures. *)
            let unified_reason =
              match deterministic_reason, is_workflow_rejection with
              | Some _, _ -> deterministic_reason
              | None, true ->
                Some Keeper_tool_deterministic_error.Workflow_rejection_blocked
              | None, false -> None
            in
            Option.iter
              (record_deterministic_tool_failure_metric ~tool_name:name)
              unified_reason;
            (match unified_reason, is_workflow_rejection with
             | Some reason, _ ->
               Log.Keeper.warn
                 "tool %s deterministic error (retry skipped, reason=%s): %s"
                 name
                 (Keeper_tool_deterministic_error.to_telemetry_key reason)
                 detail
             | None, true ->
               (* Unreachable by construction (see [unified_reason]
                  above); kept for exhaustiveness. *)
               Log.Keeper.warn
                 "tool %s deterministic error (retry skipped, reason=%s): %s"
                 name
                 (Keeper_tool_deterministic_error.to_telemetry_key
                    Keeper_tool_deterministic_error.Workflow_rejection_blocked)
                 detail
             | None, false ->
               (* MASC/OAS Error-Warn Reduction Goal §P3 adjacency
                  (2026-05-19): the same (tool, normalized detail)
                  tuple recurs as the supervisor walks the 1->2->3
                  retry ladder, so a single transient failure
                  emits at ERROR three times. Route the log
                  surface through [Keeper_tool_retry_state] so
                  attempts 2+ within the same retry cycle and
                  identical failures across cycles are demoted to
                  DEBUG, with one durable ERROR plus a Prometheus
                  counter when the silence threshold trips.

                  [WORKAROUND-CARRYOVER]: this is a noise-dedupe
                  layer. Tracked by
                  docs/rfc/RFC-0144-workaround-sunset-keeper-dedup-carryover.md.
                  Removal: whole-layer sunset criteria (RFC §4):
                  aggregate retry ERROR rate <10/day for 7 days
                  rolling AND threshold_silence counter == 0.
                  The root fix is upstream (reduce the rate of
                  tool-call failures themselves — args validation,
                  container reuse RFC-0097, etc.). *)
               let error_signature =
                 Keeper_tool_retry_state.normalize detail
               in
               (match
                  Keeper_tool_retry_state.record
                    ~tool_name:name
                    ~error_signature
                    ~attempt:count
                    ()
                with
                | `First ->
                  Log.Keeper.error
                    "tool %s returned error result (%d/%d): %s"
                    name
                    count
                    max_consecutive_failures
                    detail
                | `Repeated n ->
                  Log.Keeper.debug
                    "tool %s repeated retry log (%d/%d, total=%d, \
                     dedup): %s"
                    name
                    count
                    max_consecutive_failures
                    n
                    detail
                | `Threshold_silence n ->
                  Log.Keeper.error
                    "tool %s threshold-silence after %d identical \
                     retries: %s"
                    name
                    n
                    detail;
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_tools_oas_failures
                    ~labels:
                      [ "tool", name
                      ; "site", "retry_threshold_silence"
                      ]
                    ()));
            (* Preserve existing retry-skipped and counter semantics; only
               the human-readable WARN envelope is unified above. *)
            (match deterministic_reason with
             | Some reason ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_tools_oas_failures
                 ~labels:
                   [ "tool", name
                   ; "site"
                   , "deterministic_retry_skipped:"
                     ^ Keeper_tool_deterministic_error.to_telemetry_key reason
                   ]
                 ()
             | None -> ());
            let normalized_error =
              normalize_tool_result
                ~workflow_rejection_recovery_fields:recovery_fields
                ~success:false
                raw_result
            in
            let deterministic_decision_log_fields =
              match deterministic_reason with
              | None -> []
              | Some reason ->
                [ ( "retry_skipped"
                  , `Bool true )
                ; ( "retry_skipped_reason"
                  , `String
                      (Keeper_tool_deterministic_error.to_telemetry_key reason) )
                ]
            in
            append_tool_exec_decision_log
              ~config
              ~keeper_name:meta.name
              ~site:"error_result"
              (`Assoc
                  ([ "ts_unix", `Float ts
                  ; "event", `String "tool_exec"
                  ; "keeper_name", `String meta.name
                  ; "tool", `String name
                  ; "duration_ms", `Int duration_ms
                  ; "result_bytes", `Int (String.length normalized_error)
                  ; "ok", `Bool false
                  ; "error_preview", `String detail
                  ]
                  @ deterministic_decision_log_fields));
            Keeper_tool_call_log.set_truncation_info
              ~keeper_name:meta.name
              ~original_bytes:(String.length normalized_error)
              ();
            let output_text = Tool_output_validation.cap normalized_error in
            Tool_result.error ~tool_name:name ~start_time:t0 output_text)
          else (
            failure_count_reset failure_counts key;
            workflow_rejection_count_reset failure_counts;
            Keeper_registry.record_tool_use
              ~base_path:config.base_path
              meta.name
              ~tool_name:name
              ~success:true;
            record_keeper_internal_tool_call ~tool_name:name ~success:true ~duration_ms;
            (* Tool-call observability via OAS Event_bus. See above. *)
            (let tr =
               Tool_result.
                 { tool_name = name
                 ; success = true
                 ; duration_ms = Float.of_int duration_ms
                 ; data = `Null
                 ; legacy_message = raw_result
                 ; failure_class = None
                 }
             in
             (* RFC-0084 PR-I-3 — typed observers replace
                run_post_hooks. *)
             Tool_dispatch.run_typed_post_hooks
               Dispatch_outcome.Handled (Some tr));
            let ts = Time_compat.now () in
            broadcast_keeper_tool_call_event
              ~keeper_name:meta.name
              ~tool_name:name
              ~duration_ms
              ~success:true
              ~site:"success"
              ~ts
              ();
            (* Notify session callback (e.g., mark_used for discovered tools) *)
            (match on_tool_called with
             | Some f -> f name
             | None -> ());
            (* PR#814 Gap 1: Capture git status delta after successful tool execution.
             If the working tree changed, log it so the keeper is aware of
             file-system side effects from its tool calls. *)
            let change_block =
              Worktree_live_context.capture_change_block
                ~base_path:config.base_path
                ~actor_key:meta.name
            in
            (match change_block with
             | Some _cb ->
               Log.Keeper.info
                 "post-tool git delta detected for %s after %s"
                 meta.name
                 name
             | None -> ());
            let normalized = normalize_tool_result ~success:true raw_result in
            let final_result =
              match change_block with
              | None -> normalized
              | Some cb ->
                (* Inject changes field into the normalized JSON envelope
                 to preserve valid JSON structure. *)
                (try
                   let json = Yojson.Safe.from_string normalized in
                   match json with
                   | `Assoc fields ->
                     Yojson.Safe.to_string (`Assoc (fields @ [ "changes", `String cb ]))
                   | _ -> normalized
                 with
                 | Yojson.Json_error _ -> normalized)
            in
            let original_len = String.length final_result in
            let truncated_result = Tool_output_validation.cap final_result in
            let was_truncated = original_len > Tool_output_validation.max_output_chars in
            let result_markers = Keeper_tools_oas_markers.tool_exec_result_markers ~input ~output:final_result in
            let result_marker_fields =
              match result_markers with
              | [] -> []
              | markers ->
                [ ( "result_markers"
                  , `List (List.map (fun marker -> `String marker) markers) )
                ]
            in
            if was_truncated
            then
              Log.Keeper.info
                "tool %s output truncated: %d -> %d chars"
                name
                original_len
                (String.length truncated_result);
            append_tool_exec_decision_log
              ~config
              ~keeper_name:meta.name
              ~site:"success"
              (`Assoc
                  ([ "ts_unix", `Float ts
                   ; "event", `String "tool_exec"
                   ; "keeper_name", `String meta.name
                   ; "tool", `String name
                   ; "duration_ms", `Int duration_ms
                   ; "result_bytes", `Int original_len
                   ; "ok", `Bool true
                   ]
                   @ result_marker_fields
                   @
                   if was_truncated
                   then [ "truncated_to", `Int (String.length truncated_result) ]
                   else []));
            (* Publish truncation info for OAS hook's tool_call_log *)
            Keeper_tool_call_log.set_truncation_info
              ~keeper_name:meta.name
              ~original_bytes:original_len
              ?truncated_to:
                (if was_truncated then Some (String.length truncated_result) else None)
              ();
            Tool_result.ok ~tool_name:name ~start_time:t0 truncated_result)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          (* #10682: capture backtrace BEFORE any other operation that might
           raise/handle exceptions and clobber the raw_backtrace.  Used
           below to attach a stack to mutex EDEADLK ("Resource deadlock
           avoided") errors so the exact Stdlib.Mutex site can be
           identified — without this, the issue body for #10682 had to
           speculate across 5 candidate sites because no caller wrote
           the backtrace anywhere. *)
          let raw_bt = Printexc.get_raw_backtrace () in
          let ts = Time_compat.now () in
          let duration_ms = int_of_float ((ts -. t0) *. 1000.0) in
          let error_text = Printexc.to_string exn in
          let edeadlk_backtrace =
            (* Mutex EDEADLK signature on macOS / Linux pthread errorcheck
             mutexes is exactly this Sys_error message; targeting it
             keeps backtrace dump narrow (rare event) instead of
             spamming every routine tool error. *)
            if String_util.contains_substring error_text "Resource deadlock avoided"
            then Some (Printexc.raw_backtrace_to_string raw_bt)
            else None
          in
          let is_edeadlk = edeadlk_backtrace <> None in
          (* #10567: EDEADLK is a transient mutex-contention race in shared
           coord/keeper Stdlib.Mutex sites, not a real keeper-side failure.
           Counting it toward [failure_counts] burns the consecutive-failure
           budget (max 3) and ends the keeper turn even when the next call
           would succeed.  Skip the counter bump and downgrade the log to
           warn so dashboards don't conflate transient EDEADLK with real
           tool errors. The #10682 EDEADLK backtrace logging stays so the
           underlying Stdlib.Mutex site can still be pinpointed. *)
          let count =
            if is_edeadlk
            then failure_count_get failure_counts key
            else failure_count_record_failure failure_counts key
          in
          Keeper_registry.record_tool_use
            ~base_path:config.base_path
            meta.name
            ~tool_name:name
            ~success:false;
          record_keeper_internal_tool_call ~tool_name:name ~success:false ~duration_ms;
          (* Tool-call observability via OAS Event_bus. See above. *)
          broadcast_keeper_tool_call_event
            ~keeper_name:meta.name
            ~tool_name:name
            ~duration_ms
            ~success:false
            ~error_text
            ~extra_fields:
              (if is_edeadlk
               then
                 [ "error_class", `String transient_mutex_contention_error_class
                 ; "recoverable", `Bool true
                 ]
               else [])
            ~site:"exception"
            ~ts
            ();
          let msg =
            if is_edeadlk
            then
              Printf.sprintf
                "tool %s hit transient mutex contention (EDEADLK); not counted toward \
                 consecutive-failure budget. Retry the same call or pick a different \
                 tool."
                name
            else
              Printf.sprintf
                "tool %s failed (%d/%d): %s"
                name
                count
                max_consecutive_failures
                (Printexc.to_string exn)
          in
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_tools_oas_failures
            ~labels:[ "tool", name; "site", "exception" ]
            ();
          if is_edeadlk then Log.Keeper.warn "%s" msg else Log.Keeper.error "%s" msg;
          (match edeadlk_backtrace with
           | Some bt -> Log.Keeper.error "tool %s EDEADLK backtrace (#10682):\n%s" name bt
           | None -> ());
          let normalized_exn =
            if is_edeadlk
            then
              transient_mutex_contention_tool_error
                ~tool_name:name
                ~error_text
                ?backtrace:edeadlk_backtrace
                ()
            else normalize_tool_result ~success:false msg
          in
          append_tool_exec_decision_log
            ~config
            ~keeper_name:meta.name
            ~site:"exception"
            (`Assoc
                ([ "ts_unix", `Float ts
                 ; "event", `String "tool_exec"
                 ; "keeper_name", `String meta.name
                 ; "tool", `String name
                 ; "duration_ms", `Int duration_ms
                 ; "result_bytes", `Int (String.length normalized_exn)
                 ; "ok", `Bool false
                 ; "error", `String error_text
                 ]
                 @
                 if is_edeadlk
                 then
                   [ "error_class", `String transient_mutex_contention_error_class
                   ; "recoverable", `Bool true
                   ]
                 else []));
          Keeper_tool_call_log.set_truncation_info
            ~keeper_name:meta.name
            ~original_bytes:(String.length normalized_exn)
            ();
          let output_text = Tool_output_validation.cap normalized_exn in
          Tool_result.error ~tool_name:name ~start_time:t0 output_text
        in
        let gate_clock =
          match clock with
          | Some clock -> Some clock
          | None -> Eio_context.get_clock_opt ()
        in
        match gate_clock with
        | None -> execute_with_observers ()
        | Some clock ->
          let start_time = Time_compat.now () in
          let is_read_only =
            not
              (Keeper_exec_tools.has_mutating_side_effect_with_input
                 ~tool_name:name
                 ~input)
          in
          Tool_resource_gate.with_permit_raw
            ~clock
            ~tool_name:name
            ~arguments:input
            ~is_read_only
            ~on_reject:(fun message ->
              let payload =
                Yojson.Safe.to_string
                  (`Assoc
                     [ "ok", `Bool false
                     ; "error", `String "tool_resource_gate_saturated"
                     ; "message", `String message
                     ; "recoverable", `Bool true
                     ; "error_class", `String "transient"
                     ; "failure_class", `String "transient_error"
                     ])
              in
              Tool_result.error
                ~failure_class:(Some Tool_result.Transient_error)
                ~tool_name:name
                ~start_time
                payload)
            execute_with_observers)
;;

let make_tool_bundle
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?on_tool_called
      ?clock
      ()
  : tool_bundle
  =
  (* Phase B baseline (wise-nibbling-lerdorf plan): timestamp before the
     bundle assembly work begins; observed at function exit. *)
  let __t0 = Mtime_clock.now () in
  (* PR-3b (#11611 part 1): replace eager [Keeper_turn_sandbox_runtime]
     instances with a factory.  in_playground/cwd are unknown at
     turn-start, so the factory defers
     [Keeper_shell_docker.effective_sandbox_profile] resolution until
     each tool call site that already knows its [cwd].  The git variant
     carries a [default_network_override] so resolved runtimes always
     inherit the host network. *)
  let turn_sandbox_factory = Some (Keeper_sandbox_factory.create ~config ~meta ()) in
  let turn_sandbox_factory_git =
    Some
      (Keeper_sandbox_factory.create
         ~default_network_override:Network_inherit
         ~config
         ~meta
         ())
  in
  let exec_cache = Some (Masc_exec.Exec_cache.create ()) in
  (* Build Tool.t for the full universe so BM25 and Tool_op can
     discover tools beyond the active preset.  Progressive disclosure
     (AllowList filter in before_turn_hook) controls LLM visibility;
     execute_keeper_tool_call uses can_execute for the execution gate. *)
  let universe_names = Keeper_exec_tools.keeper_universe_tool_names meta in
  let tool_defs = Keeper_exec_tools.keeper_universe_model_tools meta in
  (* RFC-0064 Phase 2 (Copilot review #14662 threads 5/6): aliased internal
     names (e.g. keeper_bash backing public alias Bash) must NOT appear on
     the LLM-visible surface alongside their public alias.  Mirrors the
     pattern already established in [keeper_run_tools.ml] PRs #14574/#14596. *)
  let aliased_internal_names =
    List.filter_map
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r -> Some r.internal_name
         | None -> None)
      (Keeper_tool_alias.public_names ())
  in
  let alias_public_names_in_surface =
    List.filter
      (fun public ->
         match Keeper_tool_alias.route public with
         | Some r -> List.mem r.internal_name universe_names
         | None -> false)
      (Keeper_tool_alias.public_names ())
  in
  let assembled_surface_names =
    List.filter (fun n -> not (List.mem n aliased_internal_names)) universe_names
    @ alias_public_names_in_surface
  in
  (* Record tool assignment telemetry for causal tracing.
     assignment_id links Assigned → Called → Completed events.
     [tool_list] matches the actual LLM-visible surface (internal names
     minus aliased counterparts, plus public alias names), so downstream
     Assigned/Called/Completed pairing has no missing entries. *)
  let (_assignment_id : Tool_assignment_telemetry.assignment_id) =
    let lookup = Keeper_tool_policy.tool_access_lookup_of_meta meta in
    let preset =
      match meta.tool_access with
      | Preset { preset; _ } ->
        Some (Keeper_tool_policy.preset_name_of_tool_preset preset)
      | Custom _ -> None
    in
    Tool_assignment_telemetry.emit_assigned
      ~agent_id:meta.agent_name
      ~profile:"keeper"
      ?preset
      ~tool_list:assembled_surface_names
      ~allow_set:(Keeper_tool_policy.StringSet.elements lookup.allow_set)
      ~deny_set:(Keeper_tool_policy.StringSet.elements lookup.deny_set)
      ~reason:"keeper tool bundle assembly"
      ()
  in
  let failure_counts = create_failure_counts () in
  (* Pass A: internal tools that have no public alias.  Aliased internals
     are registered only via Pass B under their public name so the LLM
     surface holds at most one entry per logical tool. *)
  let internal_tools =
    List.filter_map
      (fun (td : Masc_domain.tool_schema) ->
         if
           List.mem td.name universe_names
           && not (List.mem td.name aliased_internal_names)
         then (
           let h =
             make_keeper_tool_handler
               ~name:td.name
               ~input_schema:td.input_schema
               ~config
               ~meta
               ~ctx_snapshot
               ?turn_sandbox_factory
               ?turn_sandbox_factory_git
               ~exec_cache
               ?search_fn
               ?on_tool_called
               ?clock
               ~failure_counts
               ()
           in
           Some
             (Tool_bridge.oas_tool_of_masc
                ~name:td.name
                ~description:td.description
                ~input_schema:td.input_schema
                (fun input -> h input)))
         else None)
      tool_defs
  in
  (* Pass B: RFC-0064 — register LLM-native surface names (Bash/Read/etc)
     via the flat routing table. The handler dispatches with
     [~name:r.internal_name] so all telemetry SSOT remains internal;
     only the Tool.schema.name (LLM-visible) is the public name.
     [r.translate] reshapes the LLM's payload before dispatch;
     [r.public_schema] provides the LLM-facing schema. *)
  let alias_tools =
    List.filter_map
      (fun public ->
         match Keeper_tool_alias.route public with
         | None -> None (* routing miss — should not happen for public_names *)
         | Some r ->
           let internal = r.internal_name in
           if not (List.mem internal universe_names)
           then None
           else (
             match
               List.find_opt
                 (fun (td : Masc_domain.tool_schema) -> String.equal td.name internal)
                 tool_defs
             with
             | None -> None
             | Some internal_def ->
               let input_schema =
                 match r.public_schema with
                 | Some s -> s
                 | None -> internal_def.input_schema
               in
               let description =
                 match public with
                 | "Grep" ->
                   "Search file contents with ripgrep. Use this for code/file observation; \
                    use Bash only for command execution."
                 | "Bash" ->
                   "Execute typed argv through the public Bash front door. Set cwd for \
                    multi-repo git/gh commands; use Read/Grep for file observation and \
                    visible task/board/PR tools instead of typing tool names as shell \
                    commands."
                 | _ -> internal_def.description
               in
               let h =
                 make_keeper_tool_handler
                   ~name:internal
                   ~input_schema:internal_def.input_schema
                   ~config
                   ~meta
                   ~ctx_snapshot
                   ?turn_sandbox_factory
                   ?turn_sandbox_factory_git
                   ~exec_cache
                   ?search_fn
                   ?on_tool_called
                   ?clock
                   ~translate_input:r.translate
                   ~failure_counts
                   ()
               in
               Some
                 (Tool_bridge.oas_tool_of_masc
                    ~name:public
                    ~description
                    ~input_schema
                    (fun input -> h input))))
      (Keeper_tool_alias.public_names ())
  in
  let bundle =
    { tools = internal_tools @ alias_tools
    ; cleanup =
        (fun () ->
          Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory;
          Option.iter Keeper_sandbox_factory.cleanup turn_sandbox_factory_git)
    }
  in
  Prometheus_hotpath.observe
    ~metric:Prometheus_hotpath.metric_oas_make_tool_bundle_sec
    ~start:__t0;
  bundle
;;

let make_tools
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?search_fn
      ?on_tool_called
      ?clock
      ()
  : Agent_sdk.Tool.t list
  =
  (make_tool_bundle ~config ~meta ~ctx_snapshot ?search_fn ?on_tool_called ?clock ())
    .tools
;;

