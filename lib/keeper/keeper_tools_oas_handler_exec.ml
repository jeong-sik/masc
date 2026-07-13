(** Core execution body for keeper tool OAS handler. *)

open Keeper_tools_oas
open Keeper_tools_oas_handler_telemetry

let execute_with_observers
      ~(name : string)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
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
    let is_failure =
      match result.outcome with
      | `Failure -> true
      | `Success -> false
    in
    if is_failure
    then (
      let dispatch_result =
        Tool_result.error ~tool_name:name ~start_time:t0 raw_result
      in
      let failure_class =
        match dispatch_result with
        | Error failure -> failure.class_
        | Ok _ -> Tool_result.Runtime_failure
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
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ToolsOasFailures)
        ~labels:[ "tool", name; "site", "error_result" ]
        ();
      Log.Keeper.error "tool %s returned error result: %s" name detail;
      let normalized_error = normalize_tool_result ~success:false raw_result in
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
      let output_text = Tool_output_validation.cap normalized_error in
      Tool_result.error
        ~failure_class:(Some failure_class)
        ~tool_name:name
        ~start_time:t0
        output_text)
    else (
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
      let final_result = normalize_tool_result ~success:true raw_result in
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
    let normalized_exn = normalize_tool_result ~success:false error_text in
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
    let output_text = Tool_output_validation.cap normalized_exn in
    Tool_result.error
      ~failure_class:(Some Tool_result.Runtime_failure)
      ~tool_name:name
      ~start_time:t0
      output_text
;;
