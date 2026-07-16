(** Core execution body for keeper tool OAS handler. *)

open Keeper_tools_oas
open Keeper_tools_oas_handler_telemetry

let producer_payload ~raw = function
  | Some data -> data
  | None -> `String raw
;;

let execute_with_observers
      ~(name : string)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(input : Yojson.Safe.t)
      ()
  : Tool_result.result
  =
  let t0 = Time_compat.now () in
  try
    let result, duration_ms =
      Inference_utils.timed (fun () ->
        Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome
          ~config
          ~meta
          ~publication_recovery
          ~ctx_work:ctx_snapshot
            ?turn_sandbox_factory
            ~exec_cache
          ?search_fn
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
          ())
    in
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
      (* Tool-call observability flows through the OAS Event_bus
         (ToolCalled + ToolCompleted). MASC-side observers removed
         in refactor/tool-call-single-source. *)
      (* OAS tool execution bypasses guarded_dispatch, so emit the shared
         dispatch observers explicitly. *)
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled (Some dispatch_result);
      let detail =
        raw_result |> String.trim |> Safe_ops.sanitize_text_utf8
      in
      let ts = Time_compat.now () in
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~disposition:result.disposition
        ~error_text:detail
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ())
        ~site:"error_result"
        ~ts
        ();
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ToolsOasFailures)
        ~labels:[ "tool", name; "site", "error_result" ]
        ();
      Log.Keeper.error "tool %s returned error result: %s" name detail;
      let projected_error = Tool_result.message dispatch_result in
      append_tool_exec_decision_log
        ~config
        ~keeper_name:meta.name
        ~site:"error_result"
        (`Assoc
            [ "ts_unix", `Float ts
            ; "event", `String "tool_exec"
            ; "keeper_name", `String meta.name
            ; "tool", `String name
            ; "duration_ms", `Int duration_ms
            ; "result_bytes", `Int (String.length projected_error)
            ; "disposition", `String disposition
            ; "error_preview", `String detail
            ]);
      Keeper_tool_call_log.set_truncation_info
        ~keeper_name:meta.name
        ~original_bytes:(String.length projected_error)
        ();
      dispatch_result
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
      (* Tool-call observability via OAS Event_bus. See above. *)
      (* OAS tool execution bypasses guarded_dispatch, so emit the shared
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
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ())
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
             ]));
      Keeper_tool_call_log.set_truncation_info
        ~keeper_name:meta.name
        ~original_bytes:original_len
        ();
      observed_result
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
          (tool_io_preview_fields ~tool_name:name ~input ~output:raw_result ())
        ~site:"deferred"
        ~ts
        ();
      append_tool_exec_decision_log
        ~config
        ~keeper_name:meta.name
        ~site:"deferred"
        (`Assoc
            [ "ts_unix", `Float ts
            ; "event", `String "tool_exec"
            ; "keeper_name", `String meta.name
            ; "tool", `String name
            ; "duration_ms", `Int duration_ms
            ; "result_bytes", `Int (String.length projected_result)
            ; "disposition", `String disposition
            ]);
      Keeper_tool_call_log.set_truncation_info
        ~keeper_name:meta.name
        ~original_bytes:(String.length projected_result)
        ();
      observed_result
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
    (* Tool-call observability via OAS Event_bus. See above. *)
    broadcast_keeper_tool_call_event
      ~keeper_name:meta.name
      ~tool_name:name
      ~duration_ms
      ~disposition:exception_result
      ~error_text
      ~extra_fields:
        (tool_io_preview_fields ~tool_name:name ~input ~output:error_text ())
      ~site:"exception"
      ~ts
      ();
    let msg = Printf.sprintf "tool %s failed: %s" name error_text in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ToolsOasFailures)
      ~labels:[ "tool", name; "site", "exception" ]
      ();
    Log.Keeper.error "%s" msg;
    let projected_error = Tool_result.message exception_result in
    append_tool_exec_decision_log
      ~config
      ~keeper_name:meta.name
      ~site:"exception"
      (`Assoc
          [ "ts_unix", `Float ts
          ; "event", `String "tool_exec"
          ; "keeper_name", `String meta.name
          ; "tool", `String name
          ; "duration_ms", `Int duration_ms
          ; "result_bytes", `Int (String.length projected_error)
          ; "disposition", `String disposition
          ; "error", `String error_text
          ]);
    Keeper_tool_call_log.set_truncation_info
      ~keeper_name:meta.name
      ~original_bytes:(String.length projected_error)
      ();
    exception_result
;;
