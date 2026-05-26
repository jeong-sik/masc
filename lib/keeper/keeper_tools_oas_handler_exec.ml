(** Core execution body for keeper tool OAS handler.

    Extracted from [Keeper_tools_oas_handler] so the handler skeleton
    remains focused on validation, circuit-breaking, and gating.  This
    module owns the success path, failure classification, retry-state
    management, and exception handling. *)

open Keeper_tools_oas
open Keeper_tools_oas_workflow
open Keeper_tools_oas_deterministic_error
open Keeper_tools_oas_handler_telemetry

let execute_with_observers
      ~(name : string)
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ?turn_sandbox_factory_git
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ?on_tool_called
      ~(failure_counts : failure_counts)
      ~(key : string)
      ~(input : Yojson.Safe.t)
      ()
  : Tool_result.result
  =
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
      let failure_boundary =
        Keeper_tools_oas_failure_boundary.classify_raw_failure raw_result
      in
      let is_workflow_rejection = failure_boundary.is_workflow_rejection in
      (* MASC/OAS Error-Warn Reduction Goal 2026-05-18, P2 reducer:
         classify deterministic policy/shape blocks so the LLM-driven
         1/3 -> 2/3 -> 3/3 retry loop short-circuits at the first
         attempt. Transient errors and shell exit-nonzero results
         are intentionally outside this surface (None branch). *)
      let deterministic_classification = failure_boundary.deterministic_classification in
      let deterministic_reason =
        Option.map
          (fun (classification : Keeper_tool_deterministic_error.classification) ->
             classification.reason)
          deterministic_classification
      in
      let workflow_rejection_recovery_fields =
        if is_workflow_rejection
        then (
          match workflow_rejection_info_of_raw raw_result with
          | Some info ->
            let family_key = workflow_rejection_family_key ~tool_name:name info in
            let count = workflow_rejection_count_record failure_counts family_key in
            if workflow_rejection_should_scope_block info
            then (
              match workflow_scope_key_of_input ~tool_name:name input with
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
          @
          (match deterministic_classification with
           | Some classification ->
             [ ( "retry_skipped_source"
               , `String
                   (Keeper_tool_deterministic_error.classification_source_to_string
                      classification.source) )
             ]
           | None -> [])
          @ deterministic_recovery_plan_fields raw_result
      in
      let recovery_fields =
        workflow_rejection_recovery_fields @ deterministic_recovery_fields
      in
      (* Deterministic policy/shape blocks, including explicitly
         deterministic workflow rejections: jump the per-(tool,args) failure counter to
         [max_consecutive_failures] on the first occurrence so the next
         invocation with the same args lands in the
         [prior_fails >= max_consecutive_failures] block branch at the
         top of the handler instead of executing the same rejected tool
         again. Plain workflow rejections stay on the workflow recovery
         path and do not become deterministic retry skips by class name
         alone. *)
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
      (let tr : Tool_result.result =
         Error
           { Tool_result.class_ = failure_boundary.failure_class
           ; message = raw_result
           ; data = `Null
           ; tool_name = name
           ; duration_ms = Float.of_int duration_ms
           }
       in
       (* OAS tool execution bypasses guarded_dispatch, so emit the shared
          dispatch observers explicitly. *)
       Tool_dispatch.run_dispatch_observers
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
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ())
        ~site:"error_result"
        ~ts
        ();
      Prometheus.inc_counter
        Keeper_metrics.(to_string ToolsOasFailures)
        ~labels:[ "tool", name; "site", "error_result" ]
        ();
      Option.iter
        (record_deterministic_tool_failure_metric ~tool_name:name)
        deterministic_reason;
      (match deterministic_reason, is_workflow_rejection with
       | Some reason, _ ->
         Log.Keeper.warn
           "tool %s deterministic error (retry skipped, reason=%s): %s"
           name
           (Keeper_tool_deterministic_error.to_telemetry_key reason)
           detail
       | None, true ->
         Log.Keeper.warn
           "tool %s workflow rejection (self-correction required): %s"
           name
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
              Keeper_metrics.(to_string ToolsOasFailures)
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
           Keeper_metrics.(to_string ToolsOasFailures)
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
          @
          (match deterministic_classification with
           | Some classification ->
             [ ( "retry_skipped_source"
               , `String
                   (Keeper_tool_deterministic_error.classification_source_to_string
                      classification.source) )
             ]
           | None -> [])
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
      Tool_result.error
        ~failure_class:(Some failure_boundary.failure_class)
        ~tool_name:name
        ~start_time:t0
        output_text)
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
      (let tr : Tool_result.result =
         Ok
           { Tool_result.tool_name = name
           ; data = `String raw_result
           ; duration_ms = Float.of_int duration_ms
           }
       in
       (* OAS tool execution bypasses guarded_dispatch, so emit the shared
          dispatch observers explicitly. *)
       Tool_dispatch.run_dispatch_observers
         Dispatch_outcome.Handled (Some tr));
      let ts = Time_compat.now () in
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~success:true
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ())
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
      let change_block = None in
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
        (tool_io_preview_fields ~tool_name:name ~input ~output:error_text ()
         @
         if is_edeadlk
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
      Keeper_metrics.(to_string ToolsOasFailures)
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
    Tool_result.error
      ~failure_class:
        (Some
           (if is_edeadlk
            then Tool_result.Transient_error
            else Tool_result.Runtime_failure))
      ~tool_name:name
      ~start_time:t0
      output_text
;;
