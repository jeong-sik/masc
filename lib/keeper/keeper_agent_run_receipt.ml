(** Keeper_agent_run_receipt — Receipt assembly, manifest writing, and
    turn finalization.

    Extracted from [Keeper_agent_run.run_turn] Section 6. Builds the
    execution receipt record, writes receipt manifests, appends with
    coverage-gap tracking, and determines the final turn result. *)

open Keeper_types
open Keeper_agent_result

let degraded_retry_cascade_of_wire ?(log_invalid = true) ~keeper_name raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then None
  else
    let normalized_declared =
      try Keeper_cascade_profile.normalize_declared_name trimmed with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | _ -> trimmed
    in
    let candidates =
      [ trimmed
      ; normalized_declared
      ; "tier." ^ trimmed
      ; "tier-group." ^ trimmed
      ; "route." ^ trimmed
      ]
    in
    let rec first_valid = function
      | [] -> None
      | candidate :: rest ->
        (match Cascade_name.of_string candidate with
         | Ok cascade -> Some cascade
         | Error _ -> first_valid rest)
    in
    match first_valid candidates with
    | Some _ as parsed -> parsed
    | None ->
      if log_invalid then
        Log.Keeper.warn
          "keeper:%s execution_receipt degraded_retry_cascade %S is not a \
           qualified or re-qualifiable cascade name; dropping receipt field"
          keeper_name
          raw;
      None

let finalize
    ~config
    ~meta
    ~generation
    ~manifest_keeper_turn_id
    ~cascade_name
    ~keeper_visible_sandbox_root
    ~receipt_started_at
    ~runtime_manifest_context
    ~(initial_tool_surface : Keeper_agent_tool_surface.computed_tool_surface)
    ~(acc : Keeper_run_tools.hook_accumulator)
    ~memory
    ~pre_dispatch_compacted
    ~pre_dispatch_compaction_trigger
    ~pre_dispatch_compaction_before_tokens
    ~pre_dispatch_compaction_after_tokens
    ~degraded_retry_applied
    ~degraded_retry_cascade
    ~fallback_reason
    ~cascade_rotation_attempts
    ~turn_result
    ~receipt_turn_count_ref
    ~receipt_model_used_ref
    ~receipt_stop_reason_ref
    ~receipt_cascade_observation_ref
    ~receipt_response_text_present_ref
    ~reported_tool_names_ref
    ~observed_tool_names_ref
    ~canonical_tool_names_ref
    ~unexpected_tool_names_ref
    ~actual_keeper_tool_names_ref
    ~materialized_tool_names_ref
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
  (match turn_result with
   | Ok _ -> ()
   | Error err ->
     let oas_turn_count = !receipt_turn_count_ref in
     Keeper_agent_memory_episode.record_failure
       ~config
       ~keeper_name:meta.name
       ~memory
       ~turn:manifest_keeper_turn_id
       ?oas_turn_count
       ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
       ~error_kind:
         (Memory_oas_bridge.error_kind_of_string
            (Keeper_agent_error.sdk_error_kind err))
       ~error_message:(Agent_sdk.Error.to_string err)
       ());
  let receipt_ended_at = Masc_domain.now_iso () in
  let error_kind, error_message =
    match turn_result with
    | Ok _ -> None, None
    | Error err ->
      ( Some (Keeper_execution_receipt.error_kind_of_string (Keeper_agent_error.sdk_error_kind err))
      , Some (Agent_sdk.Error.to_string err) )
  in
  let tool_contract_result
      : Keeper_execution_receipt.tool_contract_result =
    match turn_result with
    | Error (Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation _))
      ->
      (match acc.receipt_tool_contract_result with
       | Contract_unknown -> Contract_violated
       | other -> other)
    | _ -> acc.receipt_tool_contract_result
  in
  let terminal_reason_code =
    match turn_result with
    | Ok _ ->
      (match !receipt_stop_reason_ref with
       | Some sr -> Keeper_execution_receipt.stop_reason_to_string sr
       | None -> "success")
    | Error err ->
      Keeper_agent_error.terminal_reason_code_of_sdk_error_typed err
      |> Keeper_turn_terminal_code.to_wire
  in
  let cascade_observation : Cascade_observation.cascade_observation option =
    !receipt_cascade_observation_ref
  in
  let ( extra_system_context_digest
      , extra_system_context_computed_size
      , extra_system_context_injected_size ) =
    match Memory_hooks.get_last_memory_injection meta.agent_name with
    | Some (digest, computed, injected) ->
      Some digest, Some computed, Some injected
    | None -> None, None, None
  in
  let receipt =
    { Keeper_execution_receipt.keeper_name = meta.name
    ; agent_name = meta.agent_name
    ; trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
    ; generation
    ; turn_count = !receipt_turn_count_ref
    ; oas_turn_count = !receipt_turn_count_ref
    ; oas_dispatch_mode = Some "single_provider_agent_run"
    ; oas_internal_cascade_disabled = true
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
    ; requested_tools = acc.requested_tool_names_seen
    ; reported_tools = !reported_tool_names_ref
    ; observed_tools = !observed_tool_names_ref
    ; canonical_tools = !canonical_tool_names_ref
    ; unexpected_tools = !unexpected_tool_names_ref
    ; tools_used = !actual_keeper_tool_names_ref
    ; tool_contract_result
    ; tool_surface =
        { turn_lane = acc.tool_surface.turn_lane
        ; tool_surface_class = acc.tool_surface.tool_surface_class
        ; tool_requirement = acc.tool_surface.tool_requirement
        ; visible_tool_count = acc.tool_surface.visible_tool_count
        ; tool_gate_enabled = acc.tool_surface.tool_gate_enabled
        ; tool_surface_fallback_used = acc.tool_surface.tool_surface_fallback_used
        ; required_tools = acc.tool_surface.required_tool_names
        ; required_tool_candidates =
            acc.tool_surface.required_tool_candidate_names
        ; missing_required_tools = acc.tool_surface.missing_required_tool_names
        ; materialized_tools = !materialized_tool_names_ref
        }
    ; sandbox_kind = Keeper_execution_receipt.sandbox_kind_of_meta meta
    ; sandbox_root = Some keeper_visible_sandbox_root
    ; network_mode = meta.network_mode
    ; approval_profile = acc.tool_surface.approval_mode_effective
    ; approval_profile_derived = acc.tool_surface.approval_mode_derived
    ; cascade_name
    ; cascade_selected_model =
        Option.bind cascade_observation (fun obs -> obs.selected_model)
    ; cascade_attempt_count =
        (match cascade_observation with
         | Some obs -> List.length obs.attempts
         | None -> 0)
    ; cascade_fallback_applied =
        (match cascade_observation with
         | Some obs -> obs.fallback_applied
         | None -> false)
    ; cascade_outcome =
        Keeper_agent_error.cascade_outcome_of_observation cascade_observation
    ; oas_internal_cascade_allowed =
        (match cascade_observation with
         | Some obs -> obs.oas_internal_cascade_allowed
         | None -> false)
    ; degraded_retry_applied
    ; degraded_retry_cascade =
        Option.bind degraded_retry_cascade
          (degraded_retry_cascade_of_wire ~keeper_name:meta.name)
    ; fallback_reason
    ; cascade_rotation_attempts
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
        ( "cascade_name",
          `String (Cascade_name.to_string receipt.cascade_name) );
        ("cascade_attempt_count", `Int receipt.cascade_attempt_count);
        ("cascade_fallback_applied", `Bool receipt.cascade_fallback_applied);
        ( "cascade_outcome",
          `String
            (Keeper_execution_receipt.cascade_outcome_to_string
               receipt.cascade_outcome) );
        ("requested_tools", Json_util.json_string_list receipt.requested_tools);
        ("reported_tools", Json_util.json_string_list receipt.reported_tools);
        ("observed_tools", Json_util.json_string_list receipt.observed_tools);
        ("canonical_tools", Json_util.json_string_list receipt.canonical_tools);
        ("tools_used", Json_util.json_string_list receipt.tools_used);
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
      match receipt.tools_used with
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
      ~cascade_name:(Cascade_name.to_string receipt.cascade_name)
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
    match turn_result, receipt_append_outcome with
    | Error _, _ -> turn_result
    | Ok _, Ok () -> turn_result
    | Ok _, Error err_msg ->
      Error
        (Agent_sdk.Error.Internal
           (Printf.sprintf "execution_receipt_append_failed: %s" err_msg))
  in
  let final_status =
    match final_result with
    | Ok _ -> "ok"
    | Error _ -> "error"
  in
  append_receipt_manifest
    ~site:"tool_lineage"
    ~status:"recorded"
    ~decision:
      (Keeper_runtime_manifest.tool_lineage
         ~searched_tool_names:initial_tool_surface.deterministic_prefilter
         ~visible_tool_names:initial_tool_surface.all_allowed
         ~materialized_tool_names:!materialized_tool_names_ref
         ~emitted_tool_names:!reported_tool_names_ref
         ~executed_tool_names:!observed_tool_names_ref
         ~verified_tool_names:!actual_keeper_tool_names_ref
         ())
    Keeper_runtime_manifest.Tool_lineage_recorded;
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
