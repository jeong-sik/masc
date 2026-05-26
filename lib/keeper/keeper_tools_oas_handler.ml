(** Keeper_tools_oas_handler — Tool handler factory for Agent.run().

    Skeleton module: validation, circuit-breaking, workflow-rejection
    gating, and resource-gate wrapping.  The heavy execution body lives
    in [Keeper_tools_oas_handler_exec]; telemetry helpers live in
    [Keeper_tools_oas_handler_telemetry].

    @since P1 extraction *)

open Keeper_tools_oas
open Keeper_tools_oas_workflow
open Keeper_tools_oas_deterministic_error
open Keeper_tools_oas_handler_telemetry

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
  : Yojson.Safe.t -> Tool_result.result
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
      (* Validation failure is a Handler_error from the typed-outcome
         perspective; emit observers directly so metrics / usage_log still
         see it. *)
      Tool_dispatch.run_dispatch_observers
        (Dispatch_outcome.Handler_error { exn = "validation_failed" })
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
      Prometheus.inc_counter
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
    | Ok input ->
      let key = args_key input in
      let prior_fails = failure_count_get failure_counts key in
      if prior_fails >= max_consecutive_failures
      then (
        Prometheus.inc_counter
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
        match
          Option.bind
            (workflow_scope_key_of_input ~tool_name:name input)
            (workflow_rejection_scope_block_get failure_counts)
        with
        | Some block ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string ToolsOasFailures)
            ~labels:[ "tool", name; "site", "workflow_scope_blocked" ]
            ();
          record_deterministic_tool_failure_metric
            ~tool_name:name
            Keeper_tool_deterministic_error.Workflow_rejection_blocked;
          Log.Keeper.warn
            "tool %s workflow rejection retry skipped for same task/action scope"
            name;
          let raw_result =
            workflow_rejection_payload_json
              ~scope_policy:Block_scope
              ~error_class:Workflow_error_deterministic
              ~recoverability:Workflow_unrecoverable
              "workflow_rejection_open_loop_blocked"
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
          let gate_clock =
            match clock with
            | Some clock -> Some clock
            | None -> Eio_context.get_clock_opt ()
          in
          match gate_clock with
          | None ->
            Keeper_tools_oas_handler_exec.execute_with_observers
              ~name
              ~config
              ~meta
              ~ctx_snapshot
              ?turn_sandbox_factory
              ?turn_sandbox_factory_git
              ~exec_cache
              ?search_fn
              ?on_tool_called
              ~failure_counts
              ~key
              ~input
              ()
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
              (fun () ->
                Keeper_tools_oas_handler_exec.execute_with_observers
                  ~name
                  ~config
                  ~meta
                  ~ctx_snapshot
                  ?turn_sandbox_factory
                  ?turn_sandbox_factory_git
                  ~exec_cache
                  ?search_fn
                  ?on_tool_called
                  ~failure_counts
                  ~key
                  ~input
                  ()))
;;
