(** Keeper_tools_oas_handler — Tool handler factory for Agent.run().

    Skeleton module: validation, repeated-failure circuit-breaking,
    and resource-gate wrapping.  The heavy execution body lives
    in [Keeper_tools_oas_handler_exec]; telemetry helpers live in
    [Keeper_tools_oas_handler_telemetry].

    @since P1 extraction *)

open Keeper_tools_oas
open Keeper_tools_oas_deterministic_error
open Keeper_tools_oas_handler_telemetry

let make_keeper_tool_handler
      ~(name : string)
      ~(input_schema : Yojson.Safe.t)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(ctx_snapshot : Keeper_types.working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ?on_tool_called
      ?clock
      ?continuation_channel
      ?(pre_validate_input = fun input -> Ok input)
      ?(translate_input = fun j -> j)
      ?(validate_translated_input = true)
      ~(failure_counts : failure_counts)
      ()
  : Yojson.Safe.t -> Tool_result.result
  =
  let args_key input =
    let h = Hashtbl.hash (Yojson.Safe.to_string input) in
    Printf.sprintf "%s:%d" name h
  in
  fun raw_input ->
    let t0 = Time_compat.now () in
    let handle_validation_error ~input validation_result =
      let raw_result = Yojson.Safe.to_string (Tool_result.data validation_result) in
      let output_text = normalize_tool_result ~success:false raw_result in
      let duration_ms = 0 in
      let ts = Time_compat.now () in
      let error_text = Tool_result.message validation_result in
      Keeper_registry.record_tool_use
        ~base_path:config.base_path
        meta.name
        ~tool_name:name
        ~success:false;
      (* OAS input validation runs outside guarded_dispatch, so emit the
         shared dispatch observers explicitly with the same shape as the
         exec error path ([Handled] with the error result).  The rejection
         class (Workflow_rejection) rides in [validation_result] so observers
         that inspect [Tool_result.failure_class] can still distinguish it.
         Using [Handled (Some ...)] keeps the failure in the unified observer
         view; the earlier [Handler_error] arm was dropped by every observer
         (all three match only [Handled, Some _]). *)
      Tool_dispatch.run_dispatch_observers
        Dispatch_outcome.Handled
        (Some validation_result);
      broadcast_keeper_tool_call_event
        ~keeper_name:meta.name
        ~tool_name:name
        ~duration_ms
        ~success:false
        ~error_text
        ~extra_fields:
          (tool_io_preview_fields ~tool_name:name ~input ~output:output_text ())
        ~site:"input_validation"
        ~ts
        ();
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ToolsOasFailures)
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
      Tool_result.error
        ~failure_class:(Tool_result.failure_class validation_result)
        ~tool_name:name
        ~start_time:t0
        output_text
    in
    match pre_validate_input raw_input with
    | Error validation_result ->
      handle_validation_error ~input:raw_input validation_result
    | Ok pre_validated_input ->
      let input = translate_input pre_validated_input in
      (match
         if validate_translated_input
         then Tool_input_validation.validate_args ~schema:input_schema ~name ~args:input ()
         else Ok input
       with
       | Error validation_result -> handle_validation_error ~input validation_result
       | Ok input ->
         let key = args_key input in
         let prior_fails = failure_count_get failure_counts key in
         if prior_fails >= max_consecutive_failures
         then (
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string ToolsOasFailures)
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
           Tool_result.error
             ~failure_class:(Some Tool_result.Runtime_failure)
             ~tool_name:name
             ~start_time:t0
             output_text)
         else (
          let gate_clock =
            match clock with
            | Some clock -> Some clock
            | None -> Eio_context.get_clock_opt ()
          in
          let run_with_current_eio_context ?clock () =
            let sw = Eio_context.get_switch_opt () in
            let net = Eio_context.get_net_opt () in
            let proc_mgr =
              match Process_eio.get_proc_mgr () with
              | Ok proc_mgr -> Some proc_mgr
              | Error _ -> None
            in
            Keeper_tools_oas_handler_exec.execute_with_observers
              ~name
              ~config
              ~meta
              ~ctx_snapshot
              ?turn_sandbox_factory
              ~exec_cache
              ?search_fn
              ?on_tool_called
              ?sw
              ?clock
              ?proc_mgr
              ?net
              ?continuation_channel
              ~failure_counts
              ~key
              ~input
              ()
          in
          match gate_clock with
          | None -> run_with_current_eio_context ()
          | Some clock ->
            let start_time = Time_compat.now () in
            let is_read_only =
              not
                (Keeper_tool_dispatch_runtime.has_mutating_side_effect_with_input
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
              ~on_execution_timeout:(fun message ->
                let payload =
                  Yojson.Safe.to_string
                    (`Assoc
                       [ "ok", `Bool false
                       ; "error", `String "tool_resource_gate_execution_timeout"
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
              (fun () -> run_with_current_eio_context ~clock ())))
;;
