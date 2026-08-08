(** Keeper_agent_run_finalize_response — Process provider text and finalize turn.

    Extracted from [Keeper_agent_run.run_turn]. Handles response text
    finalization, checkpoint saving, contract-verification proof
    evaluation, post-turn memory, and result construction. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_result

let finalize
    ~config
    ~meta
    ~generation
    ~(profile_defaults : Keeper_types_profile.keeper_profile_defaults)
    ~manifest_keeper_turn_id
    ~session
    ~(append_manifest : Keeper_agent_run_turn_helpers.append_manifest_fn)
    ~model
    ~(acc : Keeper_run_tools.hook_accumulator)
    ~actual_keeper_tool_names
    ~(result : Runtime_agent.run_result)
    ~last_persisted_checkpoint
    ~final_oas_turn_ordinal
    ~checkpoint_persistence_error
    ~post_turn_t0
    ~runtime_id_string
    ~history_messages
    ~prompt_metrics
    ~ctx_composition
    ~usage
    ~receipt_response_text_present_ref
    ~history_assistant_source
    ~raw_response_text
    ~turn_outcome
    ~capture_replay_response
    ?continuation_delivery_channel
    () =
  let completion_contract_result = acc.receipt_completion_contract_result in
  let control_checkpoint =
    Keeper_agent_run_response_text.stop_reason_suppresses_visible_response
      result.stop_reason
  in
  let suppression_reasons =
    Keeper_replay_checkpoint.wire_capture_response_suppression_reasons
      ~control_checkpoint
  in
  let suppress_visible_response = suppression_reasons <> [] in
  let raw_response_text_present =
    String.trim raw_response_text <> ""
  in
  Keeper_replay_checkpoint.emit_wire_capture_response_suppressed_metrics
    ~keeper_name:meta.name
    suppression_reasons;
  let { Keeper_agent_run_response_text.response_text } =
    Keeper_agent_run_response_text.finalize
      ~stop_reason:result.stop_reason
      ~raw_response_text
      ~suppress_response_text:suppress_visible_response
      ()
  in
  receipt_response_text_present_ref := raw_response_text_present;
  let assistant_msg =
    Keeper_replay_checkpoint.consume_replay_response
      ~suppress_visible_response
      ~response_text
      ~consume:(fun ~response_text ->
        let assistant_msg =
          Agent_sdk.Types.make_message
           ~role:Agent_sdk.Types.Assistant
           [ Agent_sdk.Types.Text response_text ]
        in
        Keeper_context_runtime.persist_message
          ~source:history_assistant_source
          session
          assistant_msg;
        capture_replay_response ~response_text;
        assistant_msg)
  in
  let checkpoint_owner_result =
    match Runtime.get_runtime_by_id runtime_id_string with
    | Some runtime -> Ok (Runtime_execution.checkpoint_owner runtime.execution)
    | None ->
      Error
        (checkpoint_persistence_error
           ~keeper_name:meta.name
           ~detail:
             (Printf.sprintf
                "runtime disappeared before checkpoint finalization: %s"
                runtime_id_string))
  in
  let save_oas_checkpoint result_checkpoint =
    let checkpoint, source_already_persisted =
        Keeper_replay_checkpoint.select_finalization_checkpoint
          ~last_persisted_checkpoint
          result_checkpoint
      in
      let checkpoint_for_save_result =
        Keeper_replay_checkpoint.checkpoint_for_replay_persistence
          ~history_messages
          ~session_id:
            (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~response_text
          ~stop_reason:result.stop_reason
          checkpoint
      in
      (match checkpoint_for_save_result with
       | Error detail ->
         Error
           (checkpoint_persistence_error
              ~keeper_name:meta.name
              ~detail)
       | Ok (patched, replay_suffix_pruned) ->
         let already_persisted =
           Keeper_replay_checkpoint.finalization_checkpoint_already_persisted
             ~source_already_persisted
             ~source:checkpoint
             ~patched
             ~replay_suffix_pruned
         in
         let save_outcome =
           if already_persisted
           then Ok `Reused
           else
             Keeper_checkpoint_store.save_oas_classified
               ~session_dir:session.session_dir
               patched
             |> Result.map (fun outcome -> `Written outcome)
         in
         (match save_outcome with
       | Ok `Reused
       | Ok (`Written (Keeper_checkpoint_store.Saved _)) ->
         append_manifest ~site:"checkpoint_saved"
           ~keeper_turn_id:manifest_keeper_turn_id
           ~oas_turn_count:result.turns
           ~checkpoint_path:
             (Keeper_checkpoint_store.oas_checkpoint_path
                ~session_dir:session.session_dir
                ~session_id:patched.session_id)
           ~decision:
             (`Assoc
               [
                ("session_id", `String patched.session_id);
                ("turns", `Int result.turns);
                ("model", `String model);
                ( "replay_suffix_pruned"
                , `Bool (Option.is_some replay_suffix_pruned) );
                ( "replay_suffix_prune_reason"
                , (match replay_suffix_pruned with
                   | Some reason ->
                     `String
                       (Keeper_replay_checkpoint
                        .replay_suffix_prune_reason_to_string reason)
                   | None -> `Null) );
                ("pipeline_checkpoint_reused", `Bool already_persisted);
                ( "completion_contract_result"
                , `String
                    (Keeper_execution_receipt
                      .completion_contract_result_to_string
                        completion_contract_result) );
               ])
           Keeper_runtime_manifest.Checkpoint_saved;
         Ok (Some patched)
       | Ok (`Written (Keeper_checkpoint_store.Stale_noop
                { incoming_turn_count; known_turn_count })) ->
         Log.Keeper.warn ~keeper_name:meta.name
           "runtime=%s OAS checkpoint stale no-op: incoming turn_count=%d, last saved=%d"
           (Keeper_meta_contract.runtime_id_of_meta meta)
           incoming_turn_count known_turn_count;
         Otel_metric_store.inc_counter
           "masc_keeper_checkpoint_stale_noop_total"
           ~labels:[ "keeper", meta.name; "site", "finalize" ]
           ();
         Ok None
       | Error e ->
         Log.Keeper.error ~keeper_name:meta.name
           "runtime=%s OAS checkpoint save failed: %s"
           (Keeper_meta_contract.runtime_id_of_meta meta)
           e;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string CheckpointFailures)
           ~labels:[ "keeper", meta.name; "site", "save" ]
           ();
         Error
           (checkpoint_persistence_error
              ~keeper_name:meta.name
              ~detail:("OAS checkpoint save failed: " ^ e))))
  in
  let missing_oas_checkpoint () =
      Log.Keeper.error ~keeper_name:meta.name
        "runtime=%s missing OAS checkpoint after run"
        (Keeper_meta_contract.runtime_id_of_meta meta);
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CheckpointFailures)
        ~labels:[ "keeper", meta.name; "site", "missing" ]
        ();
      Error
        (checkpoint_persistence_error
           ~keeper_name:meta.name
           ~detail:"missing OAS checkpoint after run")
  in
  let unexpected_oas_checkpoint () =
    Log.Keeper.error ~keeper_name:meta.name
      "runtime=%s official-client runtime returned an OAS checkpoint"
      (Keeper_meta_contract.runtime_id_of_meta meta);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[ "keeper", meta.name; "site", "owner_mismatch" ]
      ();
    Error
      (checkpoint_persistence_error
         ~keeper_name:meta.name
         ~detail:"official-client runtime returned an OAS checkpoint")
  in
  let saved_checkpoint_result =
    match checkpoint_owner_result, result.checkpoint with
    | Error error, _ -> Error error
    | Ok Runtime_execution.Masc_oas, Some result_checkpoint ->
      save_oas_checkpoint result_checkpoint
    | Ok Runtime_execution.Masc_oas, None -> missing_oas_checkpoint ()
    | Ok Runtime_execution.Official_client, Some _ ->
      unexpected_oas_checkpoint ()
    | Ok Runtime_execution.Official_client, None -> Ok None
  in
  match saved_checkpoint_result with
  | Error e -> Error e
  | Ok saved_checkpoint ->
    (* Retired proof-ledger evaluation is absent. Strict Task completion
       judgment is owned by the authenticated operator or typed judge
       boundary. *)
    let librarian_messages =
      match saved_checkpoint with
      | Some checkpoint -> checkpoint.Agent_sdk.Checkpoint.messages
      | None -> Option.to_list assistant_msg
    in
    Keeper_agent_run_post_turn_memory.run
      ~config
      ~meta
      ~generation
      ~turn:manifest_keeper_turn_id
      ~oas_turn_count:result.turns
      ~actual_tools:actual_keeper_tool_names
      ~librarian_messages
      ~post_turn_t0
      ~inference_telemetry:result.response.telemetry
      ();
    Ok
      { response_text
      ; turn_outcome
      ; model_used = model
      ; prompt_metrics
      ; ctx_composition
      ; runtime_observation = result.runtime_observation
      ; turn_count = result.turns
      ; final_oas_turn_ordinal
      ; usage
      ; usage_reported = Option.is_some result.response.usage
      ; tool_calls = List.rev acc.tool_calls
      ; completion_contract_result
      ; operator_disposition = None
      ; checkpoint = saved_checkpoint
      ; trace_ref = result.trace_ref
      ; run_validation = result.run_validation
      ; stop_reason = result.stop_reason
      ; inference_telemetry = result.response.telemetry
      ; tool_surface = acc.tool_surface
      }
;;
