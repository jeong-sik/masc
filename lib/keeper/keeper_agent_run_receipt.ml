(** Keeper_agent_run_receipt — Receipt assembly, manifest writing, and
    turn finalization.

    Extracted from [Keeper_agent_run.run_turn] Section 6. Builds the
    execution receipt record, writes receipt manifests, appends with
    coverage-gap tracking, and determines the final turn result. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_result

let degraded_retry_runtime_of_wire ?(log_invalid = true) ~keeper_name raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None
  else
    let normalized_declared =
      try String.trim trimmed with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> trimmed
    in
    let candidates =
      [ trimmed
      ; normalized_declared
      ; "route." ^ trimmed
      ]
    in
    (* RFC-0206: a runtime id is a raw string (no runtime-name prefix
       validation / re-qualification). Accept the first non-empty candidate. *)
    let rec first_valid = function
      | [] -> None
      | candidate :: rest ->
        if String.trim candidate = "" then first_valid rest else Some candidate
    in
    match first_valid candidates with
    | Some _ as parsed -> parsed
    | None ->
      if log_invalid then
        Log.Keeper.warn ~keeper_name:keeper_name
          "execution_receipt degraded_retry_runtime %S is not a \
           qualified or re-qualifiable runtime name; dropping receipt field"
          raw;
      None

let finalize
    ~config
    ~meta
    ~generation
    ~manifest_keeper_turn_id
    ~runtime_id
    ~keeper_visible_sandbox_root
    ~receipt_started_at
    ~runtime_manifest_context
    ~(acc : Keeper_run_tools.hook_accumulator)
    ~pre_dispatch_compacted
    ~pre_dispatch_compaction_trigger
    ~pre_dispatch_compaction_before_tokens
    ~pre_dispatch_compaction_after_tokens
    ~degraded_retry_applied
    ~degraded_retry_runtime
    ~fallback_reason
    ~runtime_rotation_attempts
    ~turn_result
    ~receipt_turn_count_ref
    ~receipt_model_used_ref
    ~receipt_stop_reason_ref
    ~receipt_runtime_observation_ref
    ~receipt_response_text_present_ref
    () =
  (match turn_result with
   | Ok _ -> ()
   | Error err ->
     let status, exception_kind =
       match err with
       | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _) ->
         "timeout", Some "outer_oas_timeout"
       | _ -> "error", Some "outer_oas_error"
     in
     Keeper_runtime_manifest
       .append_unfinished_provider_attempt_finished_best_effort
         ~site:"keeper_llm_bridge_terminal"
         config
         runtime_manifest_context
         ~status
         ~error:(Agent_sdk.Error.to_string err)
         ?exception_kind
         ());
  let receipt_ended_at = Masc_domain.now_iso () in
  let error_kind, error_message =
    match turn_result with
    | Ok _ -> None, None
    | Error err ->
      ( Some (Keeper_agent_error.sdk_error_kind_for_receipt err)
      , Some (Agent_sdk.Error.to_string err) )
  in
  let completion_contract_result
      : Keeper_execution_receipt.completion_contract_result =
    match turn_result with
    | _ -> acc.receipt_completion_contract_result
  in
  let terminal_reason_code =
    match turn_result with
    | Ok _ ->
      (match !receipt_stop_reason_ref with
       | Some sr ->
         Keeper_execution_receipt.receipt_terminal_reason_code_of_stop_reason sr
       | None ->
         Keeper_turn_disposition.to_wire Keeper_turn_disposition.Success)
    | Error err ->
      Keeper_agent_error.terminal_reason_code_of_sdk_error_typed err
      |> Keeper_turn_terminal_code.to_wire
  in
  let runtime_observation : Runtime_observation.runtime_observation option =
    !receipt_runtime_observation_ref
  in
  (* #20936: the before_turn_params hook snapshots the final injected
     extra_system_context (digest + byte size) into the accumulator each
     SDK turn; the receipt reports the last SDK turn's values. The SDK
     injects the assembled string verbatim, so computed and injected
     sizes coincide — they diverge only if an injection-side truncation
     layer ever appears. *)
  let extra_system_context_digest =
    acc.Keeper_run_tools.extra_system_context_digest
  in
  let extra_system_context_computed_size =
    acc.Keeper_run_tools.extra_system_context_size
  in
  let extra_system_context_injected_size =
    acc.Keeper_run_tools.extra_system_context_size
  in
  let receipt =
    { Keeper_execution_receipt.keeper_name = meta.name
    ; agent_name = meta.agent_name
    ; trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
    ; generation
    ; turn_count = !receipt_turn_count_ref
    ; oas_turn_count = !receipt_turn_count_ref
    ; oas_dispatch_mode = Some "single_provider_agent_run"
    ; oas_internal_runtime_disabled = true
    ; current_task_id =
        Option.map Keeper_id.Task_id.to_string acc.meta.current_task_id
    ; goal_ids = meta.active_goal_ids
    ; outcome =
        (match turn_result with
         | Ok _ -> `Ok
         | Error err ->
           Keeper_agent_error.receipt_outcome_kind_of_sdk_error err)
    ; terminal_reason_code
    ; response_text_present = !receipt_response_text_present_ref
    ; model_used = !receipt_model_used_ref
    ; completion_contract_result
    ; actionable_signal = acc.receipt_actionable_signal
    ; tool_surface =
        { turn_lane = acc.tool_surface.turn_lane }
    ; sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta
    ; sandbox_root = Some keeper_visible_sandbox_root
    ; network_mode = meta.network_mode
    ; runtime_id
    ; runtime_selected_model =
        Option.bind runtime_observation (fun obs -> obs.selected_model)
    ; runtime_attempt_count =
        (match runtime_observation with
         | Some obs -> List.length obs.attempts
         | None -> 0)
    ; runtime_fallback_applied =
        (match runtime_observation with
         | Some obs -> obs.fallback_applied
         | None -> false)
    ; runtime_outcome =
        Keeper_agent_error.runtime_outcome_of_observation runtime_observation
    ; oas_internal_runtime_allowed =
        (match runtime_observation with
         | Some obs -> obs.oas_internal_runtime_allowed
         | None -> false)
    ; degraded_retry_applied
    ; degraded_retry_runtime =
        Option.bind degraded_retry_runtime
          (degraded_retry_runtime_of_wire ~keeper_name:meta.name)
    ; fallback_reason
    ; runtime_rotation_attempts
    ; stop_reason = !receipt_stop_reason_ref
    ; error_kind
    ; error_message
    ; started_at = receipt_started_at
    ; ended_at = receipt_ended_at
    ; extra_system_context_digest
    ; extra_system_context_computed_size
    ; extra_system_context_injected_size
    ; pre_dispatch_compacted
    ; pre_dispatch_compaction_trigger
    ; pre_dispatch_compaction_before_tokens
    ; pre_dispatch_compaction_after_tokens
    }
  in
  let disposition, reason = Keeper_execution_receipt.operator_disposition receipt in
  let operator_disposition =
    Some ({ disposition; reason } : Keeper_agent_result.operator_disposition)
  in
  let turn_result_with_operator_disposition =
    match turn_result with
    | Ok result -> Ok { result with operator_disposition }
    | Error _ -> turn_result
  in
  let receipt_path =
    Keeper_runtime_manifest.execution_receipt_path_for_today config
      ~keeper_name:meta.name
  in
  let receipt_manifest_decision ?receipt_append_ok () =
    `Assoc
      [
        ( "outcome",
          `String
            (Keeper_execution_receipt.outcome_kind_to_string receipt.outcome) );
        ("terminal_reason_code", `String receipt.terminal_reason_code);
        ( "runtime_id",
          `String (receipt.runtime_id) );
        ("runtime_attempt_count", `Int receipt.runtime_attempt_count);
        ("runtime_fallback_applied", `Bool receipt.runtime_fallback_applied);
        ( "runtime_outcome",
          `String
            (Keeper_execution_receipt.runtime_outcome_to_string
               receipt.runtime_outcome) );
        ( "receipt_append_ok",
          match receipt_append_ok with
          | None -> `Null
          | Some ok -> `Bool ok );
      ]
  in
  let append_receipt_manifest ?status ?decision ~site event =
    let oas_turn_count = receipt.turn_count in
    let status =
      match status with
      | Some status -> status
      | None ->
        Keeper_execution_receipt.outcome_kind_to_string receipt.outcome
    in
    let decision =
      match decision with
      | Some decision -> decision
      | None -> receipt_manifest_decision ()
    in
    let tool_call_log_path =
      match acc.tool_calls with
      | [] -> None
      | _ -> Keeper_tool_call_log.current_log_path ()
    in
    let clock_refs =
      Keeper_runtime_manifest.clock_refs_for_context
        runtime_manifest_context ~event ()
    in
    let decision =
      Keeper_runtime_manifest.with_clock_refs ~clock_refs decision
    in
    Keeper_runtime_manifest.make ~ts:receipt.ended_at
      ~keeper_name:receipt.keeper_name ~agent_name:receipt.agent_name
      ~trace_id:receipt.trace_id ~generation:receipt.generation
      ~keeper_turn_id:manifest_keeper_turn_id ~event
      ?oas_turn_count
      ~runtime_id:(receipt.runtime_id)
      ~status ~decision ~receipt_path ?tool_call_log_path ()
    |> Keeper_runtime_manifest.append_best_effort ~site config
  in
  let receipt_append_outcome : (unit, string) result =
    Keeper_agent_run_receipt_append.append_with_coverage_gap
      ~config
      ~receipt
      ~keeper_name:meta.name
      ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      ~on_appended:(fun () ->
        append_receipt_manifest
          ~site:"receipt_appended"
          Keeper_runtime_manifest.Receipt_appended)
  in
  Keeper_agent_run_phase5_task_link.run ~config ~meta ~acc ();
  let final_result =
    match turn_result_with_operator_disposition, receipt_append_outcome with
    | Error _, _ -> turn_result_with_operator_disposition
    | Ok _, Ok () -> turn_result_with_operator_disposition
    | Ok _, Error err_msg ->
      Error
        (Keeper_internal_error.sdk_error_of_masc_internal_error
           (Keeper_internal_error.Receipt_persistence_failed
              { detail = err_msg }))
  in
  let final_status =
    match final_result with
    | Ok _ -> "ok"
    | Error _ -> "error"
  in
  append_receipt_manifest
    ~site:"turn_finished"
    ~status:final_status
    ~decision:
      (`Assoc
        [
          ( "turn_result",
            `String
              (match turn_result with
               | Ok _ -> "ok"
               | Error _ -> "error") );
          ( "receipt_append_ok",
            `Bool
              (match receipt_append_outcome with
               | Ok () -> true
               | Error _ -> false) );
          ("terminal_reason_code", `String terminal_reason_code);
        ])
    Keeper_runtime_manifest.Turn_finished;
  final_result
;;
