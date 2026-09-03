(** Core execution body for keeper tool AGENT_CORE handler. *)

open Keeper_tools_agent_core
open Keeper_tools_agent_core_handler_telemetry

type execution_result =
  { tool_result : Tool_result.result
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; terminal_effect_receipt : Keeper_tool_execution.terminal_effect_receipt option
  }

let producer_payload ~raw = function
  | Some data -> data
  | None -> `String raw
;;

let execute_with_observers_with_authority
      ~capability_authority
      ~(name : string)
      ?descriptor
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ?agent_core_invocation
      ~(input : Yojson.Safe.t)
      ()
  : execution_result
  =
  let t0 = Time_compat.now () in
  let invocation_fields = agent_core_invocation_fields agent_core_invocation in
  let set_truncation_info ~original_bytes =
    Option.iter
      (fun invocation ->
         Keeper_tool_call_log.set_truncation_info
           ~invocation
           ~original_bytes
           ())
      agent_core_invocation
  in
  try
    let result, duration_ms =
      Inference_utils.timed (fun () ->
        match descriptor, capability_authority with
        | None, Keeper_tool_runtime.Frozen_surface capability_surface ->
          Keeper_tool_dispatch_runtime.execute_keeper_tool_call_for_capability_surface_with_outcome
            ~capability_surface
            ~config
            ~meta
            ~publication_recovery
            ~ctx_work:ctx_snapshot
            ?turn_sandbox_factory
            ?sw
            ?clock
            ?proc_mgr
            ?net
            ?mcp_session_id
            ?continuation_channel
            ?gate_context
            ?gate_grant
            ~name
            ~input
            ()
        | Some descriptor, Keeper_tool_runtime.Frozen_surface capability_surface ->
          Keeper_tool_dispatch_runtime.execute_keeper_tool_descriptor_for_capability_surface_with_outcome
            ~capability_surface
            ~config
            ~meta
            ~publication_recovery
            ~ctx_work:ctx_snapshot
            ?turn_sandbox_factory
            ?sw
            ?clock
            ?proc_mgr
            ?net
            ?mcp_session_id
            ?continuation_channel
            ?gate_context
            ?gate_grant
            ~descriptor
            ~input
            ()
        | None, Keeper_tool_runtime.Compatibility_meta ->
          Keeper_tool_dispatch_runtime.Compatibility.execute_keeper_tool_call_with_outcome
            ~config
            ~meta
            ~publication_recovery
            ~ctx_work:ctx_snapshot
            ?turn_sandbox_factory
            ?sw
            ?clock
            ?proc_mgr
            ?net
            ?mcp_session_id
            ?continuation_channel
            ?gate_context
            ?gate_grant
            ~name
            ~input
            ()
        | Some descriptor, Keeper_tool_runtime.Compatibility_meta ->
          Keeper_tool_dispatch_runtime.Compatibility.execute_keeper_tool_descriptor_with_outcome
            ~config
            ~meta
            ~publication_recovery
            ~ctx_work:ctx_snapshot
            ?turn_sandbox_factory
            ?sw
            ?clock
            ?proc_mgr
            ?net
            ?mcp_session_id
            ?continuation_channel
            ?gate_context
            ?gate_grant
            ~descriptor
            ~input
            ())
    in
    (* Carried to the row writer beside the truncation info, which crosses the
       same boundary for the same reason. Two other stores already receive
       this value below; the per-call row is the one that had to infer it. *)
    Option.iter
      (fun invocation ->
         Keeper_tool_call_log.set_disposition
           ~invocation
           ~disposition:result.Keeper_tool_execution.disposition;
         Option.iter
           (fun evidence ->
              Keeper_tool_call_log.set_file_change_evidence
                ~invocation
                ~evidence)
           result.file_change_evidence)
      agent_core_invocation;
    let raw_result = result.Keeper_tool_execution.raw_output in
    let producer_data = result.data in
    let producer_metadata = result.metadata in
    let disposition = Tool_result.string_of_disposition result.disposition in
    match result.disposition with
    | Tool_result.Failed failure_class ->
      let dispatch_result =
        Tool_result.make_err
          ~tool_name:name
          ~class_:failure_class
          ~start_time:t0
          ~data:(producer_payload ~raw:raw_result producer_data)
          ?metadata:producer_metadata
          raw_result
      in
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~disposition:result.disposition;
      record_keeper_internal_tool_call
        ~tool_name:name
        ~disposition:result.disposition
        ~duration_ms;
      (* Tool-call observability flows through the AGENT_CORE Event_bus
         (ToolCalled + ToolCompleted). MASC-side observers removed
         in refactor/tool-call-single-source. *)
      (* AGENT_CORE tool execution bypasses guarded_dispatch, so emit the shared
         dispatch observers explicitly. *)
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled (Some dispatch_result);
      (* Bound before sanitizing, not after.  [raw_result] is whatever the
         tool wrote, and a tool that dumps a file returns the whole file: a
         single [tool_execute] error on 2026-08-06 produced a 699,341,105-byte
         [detail], which became 94.3% of that day's 708 MB system log, a
         618,922,307-byte blob, and one SSE broadcast of the same bytes.

         The sibling telemetry on this very call already bounds the same
         string — [tool_io_preview_fields ~output:raw_result] routes through
         [Observability_redact.redact_tool_output]. [error_text] was the one
         consumer that skipped the redactor, so it also skipped secret
         masking.

         Truncating first means [sanitize_text_utf8] scans at most
         [max_tool_result_wire_bytes] instead of the whole payload, and it repairs
         any multi-byte character the cut split. *)
      let detail =
        raw_result
        |> Observability_redact.redact_preview
             ~max_len:Common.max_tool_result_wire_bytes
        |> Safe_ops.sanitize_text_utf8
      in
      let ts = Time_compat.now () in
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~disposition:result.disposition
        ~error_text:detail
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ()
           @ invocation_fields)
        ~site:"error_result"
        ~ts
        ();
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ToolsAgent_coreFailures)
        ~labels:[ "tool", name; "site", "error_result" ]
        ();
      (* SSOT: the failure class owns its log level — a policy/workflow/
         transient/operator-cancelled rejection is an expected outcome on
         this path, not an Error-level event (#28895 review). *)
      Log.Keeper.emit
        (Tool_result.log_level_of_failure_class failure_class)
        (Printf.sprintf "tool %s returned error result: %s" name detail);
      let projected_error = Tool_result.message dispatch_result in
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
            ; "result_bytes", `Int (String.length projected_error)
            ; "disposition", `String disposition
            ; "error_preview", `String detail
            ]
             @ invocation_fields));
      set_truncation_info ~original_bytes:(String.length projected_error);
      { tool_result = dispatch_result
      ; failure_effect_disposition = Some result.failure_effect_disposition
      ; deferred_kind = None
      ; terminal_effect_receipt = None
      }
    | Tool_result.Completed () ->
      Option.iter
        (Keeper_tool_emission_hook.capture_typed_result_for_keeper
           ~keeper_name:meta.name)
        producer_data;
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~disposition:result.disposition;
      record_keeper_internal_tool_call
        ~tool_name:name
        ~disposition:result.disposition
        ~duration_ms;
      let observed_result : Tool_result.result =
        Tool_result.Completed
          { Tool_result.tool_name = name
          ; data = producer_payload ~raw:raw_result producer_data
          ; metadata = producer_metadata
          ; duration_ms = Float.of_int duration_ms
          }
      in
      (* Tool-call observability via AGENT_CORE Event_bus. See above. *)
      (* AGENT_CORE tool execution bypasses guarded_dispatch, so emit the shared
         dispatch observers explicitly. *)
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled (Some observed_result);
      let ts = Time_compat.now () in
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~disposition:result.disposition
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ()
           @ invocation_fields)
        ~site:"success"
        ~ts
        ();
      let projected_result = Tool_result.message observed_result in
      let original_len = String.length projected_result in
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
             ; "disposition", `String disposition
             ]
             @ invocation_fields));
      set_truncation_info ~original_bytes:original_len;
      { tool_result = observed_result
      ; failure_effect_disposition = None
      ; deferred_kind = None
      ; terminal_effect_receipt = result.terminal_effect_receipt
      }
    | Tool_result.Deferred () ->
      Option.iter
        (Keeper_tool_emission_hook.capture_typed_result_for_keeper
           ~keeper_name:meta.name)
        producer_data;
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~disposition:result.disposition;
      record_keeper_internal_tool_call
        ~tool_name:name
        ~disposition:result.disposition
        ~duration_ms;
      let observed_result : Tool_result.result =
        Tool_result.Deferred
          { Tool_result.tool_name = name
          ; data = producer_payload ~raw:raw_result producer_data
          ; metadata = producer_metadata
          ; duration_ms = Float.of_int duration_ms
          }
      in
      let projected_result = Tool_result.message observed_result in
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled (Some observed_result);
      let ts = Time_compat.now () in
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~disposition:result.disposition
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ()
           @ invocation_fields)
        ~site:"deferred"
        ~ts
        ();
      append_tool_exec_decision_log
        ~config
        ~keeper_name:meta.name
        ~site:"deferred"
        (`Assoc
            ([ "ts_unix", `Float ts
            ; "event", `String "tool_exec"
            ; "keeper_name", `String meta.name
            ; "tool", `String name
            ; "duration_ms", `Int duration_ms
            ; "result_bytes", `Int (String.length projected_result)
            ; "disposition", `String disposition
            ]
             @ invocation_fields));
      set_truncation_info ~original_bytes:(String.length projected_result);
      { tool_result = observed_result
      ; failure_effect_disposition = None
      ; deferred_kind = result.deferred_kind
      ; terminal_effect_receipt = None
      }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let ts = Time_compat.now () in
    let duration_ms = int_of_float ((ts -. t0) *. 1000.0) in
    let error_text = Printexc.to_string exn in
    let exception_result =
      Tool_result.make_err
        ~class_:Tool_result.Runtime_failure
        ~tool_name:name
        ~start_time:t0
        error_text
    in
    let disposition =
      Tool_result.string_of_disposition exception_result
    in
    Keeper_registry.record_tool_use
      ~base_path:config.base_path
      meta.name
      ~tool_name:name
      ~disposition:exception_result;
    record_keeper_internal_tool_call
      ~tool_name:name
      ~disposition:exception_result
      ~duration_ms;
    (* Tool-call observability via AGENT_CORE Event_bus. See above. *)
    broadcast_keeper_tool_call_event
      ~keeper_name:meta.name
      ~tool_name:name
      ~duration_ms
      ~disposition:exception_result
      ~error_text
      ~extra_fields:
        (tool_io_preview_fields ~tool_name:name ~input ~output:error_text ()
         @ invocation_fields)
      ~site:"exception"
      ~ts
      ();
    let msg = Printf.sprintf "tool %s failed: %s" name error_text in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ToolsAgent_coreFailures)
      ~labels:[ "tool", name; "site", "exception" ]
      ();
    Log.Keeper.error "%s" msg;
    let projected_error = Tool_result.message exception_result in
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
          ; "result_bytes", `Int (String.length projected_error)
          ; "disposition", `String disposition
          ; "error", `String error_text
          ]
           @ invocation_fields));
    set_truncation_info ~original_bytes:(String.length projected_error);
    { tool_result = exception_result
    ; failure_effect_disposition = Some Tool_result.Effect_outcome_unknown
    ; deferred_kind = None
    ; terminal_effect_receipt = None
    }
;;

let execute_with_observers ~capability_surface =
  execute_with_observers_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
;;

let execute_with_observers_from_meta =
  execute_with_observers_with_authority
    ~capability_authority:Keeper_tool_runtime.Compatibility_meta
;;
