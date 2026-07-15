(** Core execution body for keeper tool OAS handler. *)

open Keeper_tools_oas
open Keeper_tools_oas_handler_telemetry

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
    let raw_result = result.raw_output in
    let producer_data = result.data in
    match result.outcome with
    | `Failure failure_class ->
      let dispatch_result =
        Tool_result.make_err
          ~tool_name:name
          ~class_:failure_class
          ~start_time:t0
          ~data:(Option.value ~default:(`String raw_result) producer_data)
          raw_result
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
        ~success:false
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
      (* Honor the declared per-class severity (Tool_result.log_level_of_
         failure_class): Workflow_rejection / Policy_rejection / Transient_error
         are WARN, Runtime_failure is ERROR. Hardcoding ERROR here logged
         expected non-blocking gate deferrals (Workflow_rejection) as errors,
         producing false alarms. Same idiom as mcp_server_eio_call_tool.ml and
         keeper_tool_in_process_runtime.ml. *)
      Log.Keeper.emit
        (Tool_result.log_level_of_failure_class failure_class)
        ~category:Log.Tool
        (Printf.sprintf "tool %s returned error result: %s" name detail);
      let normalized_error_json =
        normalize_tool_result ~success:false ~data:producer_data raw_result
      in
      let normalized_error = Yojson.Safe.to_string normalized_error_json in
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
            ; "result_bytes", `Int (String.length normalized_error)
            ; "ok", `Bool false
            ; "error_preview", `String detail
            ]);
      Keeper_tool_call_log.set_truncation_info
        ~keeper_name:meta.name
        ~original_bytes:(String.length normalized_error)
        ();
      Tool_result.make_err
        ~class_:failure_class
        ~tool_name:name
        ~start_time:t0
        ~data:normalized_error_json
        normalized_error
    | `Success ->
      Option.iter
        (Keeper_tool_emission_hook.capture_typed_result_for_keeper
           ~keeper_name:meta.name)
        producer_data;
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
           ; data = Option.value ~default:(`String raw_result) producer_data
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
      let final_result_json =
        normalize_tool_result ~success:true ~data:producer_data raw_result
      in
      let final_result = Yojson.Safe.to_string final_result_json in
      let original_len = String.length final_result in
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
             ]));
      Keeper_tool_call_log.set_truncation_info
        ~keeper_name:meta.name
        ~original_bytes:original_len
        ();
      Tool_result.make_ok
        ~tool_name:name
        ~start_time:t0
        ~data:final_result_json
        ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let ts = Time_compat.now () in
    let duration_ms = int_of_float ((ts -. t0) *. 1000.0) in
    let error_text = Printexc.to_string exn in
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
    let normalized_exn_json =
      normalize_tool_result ~success:false ~data:None error_text
    in
    let normalized_exn = Yojson.Safe.to_string normalized_exn_json in
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
          ; "result_bytes", `Int (String.length normalized_exn)
          ; "ok", `Bool false
          ; "error", `String error_text
          ]);
    Keeper_tool_call_log.set_truncation_info
      ~keeper_name:meta.name
      ~original_bytes:(String.length normalized_exn)
      ();
    Tool_result.make_err
      ~class_:Tool_result.Runtime_failure
      ~tool_name:name
      ~start_time:t0
      ~data:normalized_exn_json
      normalized_exn
;;
