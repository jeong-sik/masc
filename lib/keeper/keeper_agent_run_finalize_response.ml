(** Keeper_agent_run_finalize_response — Process provider text and finalize turn.

    Extracted from [Keeper_agent_run.run_turn]. Handles response text
    finalization, checkpoint saving, contract-verification proof
    evaluation, post-turn memory, and result construction. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_result

type replay_suffix_prune_reason =
  | Canonical_success_replay

let replay_suffix_prune_reason_to_string = function
  | Canonical_success_replay -> "canonical_success_replay"
;;

let replay_response_text_for_capture ~suppress_visible_response ~response_text =
  if suppress_visible_response || String.trim response_text = ""
  then None
  else Some response_text
;;

type wire_capture_response_suppression_reason =
  | Control_checkpoint

let wire_capture_response_suppression_reasons ~control_checkpoint =
  if control_checkpoint then [ Control_checkpoint ] else []
;;

let wire_capture_response_suppression_reason_label = function
  | Control_checkpoint -> "control_checkpoint"
;;

let emit_wire_capture_response_suppressed_metric ~keeper_name reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string WireCaptureResponseSuppressed)
    ~labels:
      [ ("keeper", keeper_name)
      ; ("reason", wire_capture_response_suppression_reason_label reason)
      ]
    ()
;;

let emit_wire_capture_response_suppressed_metrics ~keeper_name reasons =
  List.iter
    (emit_wire_capture_response_suppressed_metric ~keeper_name)
    reasons
;;

let canonical_success_replay_checkpoint
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_sdk.Checkpoint.messages
  with
  | Ok current_suffix ->
    let dropped_current_turn_replay = current_suffix <> [] in
    let checkpoint =
      if String.trim response_text = ""
      then
        { checkpoint with
          Agent_sdk.Checkpoint.session_id
        ; messages = Keeper_context_core.repair_broken_tool_call_pairs history_messages
        ; working_context = None
        }
      else
        let messages =
          if
            List.exists
              (fun (msg : Agent_sdk.Types.message) ->
                 msg.role = Agent_sdk.Types.Assistant)
              current_suffix
          then checkpoint.Agent_sdk.Checkpoint.messages
          else
            checkpoint.Agent_sdk.Checkpoint.messages
            @
            [ Agent_sdk.Types.make_message
                ~role:Agent_sdk.Types.Assistant
                [ Agent_sdk.Types.Text response_text ]
            ]
        in
        Keeper_context_core.patch_checkpoint_last_assistant
          { checkpoint with
            Agent_sdk.Checkpoint.messages =
              Keeper_context_core.repair_broken_tool_call_pairs messages
          }
          ~session_id
          ~response_text
    in
    Ok
      ( checkpoint
      , if dropped_current_turn_replay
        then Some Canonical_success_replay
        else None )
  | Error _ ->
    Error
      "refusing to save checkpoint: canonical replay persistence requires \
       checkpoint messages to match pre-turn history prefix"
;;

let observation_replay_checkpoint
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match
    Keeper_replay_prefix.split
      ~prefix:history_messages
      checkpoint.Agent_sdk.Checkpoint.messages
  with
  | Ok _ ->
    Ok
      ( { checkpoint with
          Agent_sdk.Checkpoint.session_id
        }
      , None )
  | Error _ ->
    Error
      "refusing to save execution-observation checkpoint: messages do not match pre-turn history prefix"
;;

let checkpoint_for_replay_persistence
      ~(history_messages : Agent_sdk.Types.message list)
      ~pre_turn_working_context:_
      ~completion_contract_result:_
      ~(session_id : string)
      ~(response_text : string)
      ?(stop_reason = Runtime_agent.Completed)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match stop_reason with
  | Runtime_agent.InputRequired _
  | Runtime_agent.ToolFailureRecoveryDeferred _ ->
    (* OAS attached the durable recovery receipt to the current ToolResult.
       Blank-response canonicalization and completion-contract pruning both
       remove that suffix, so this typed control checkpoint must preserve it
       verbatim. Prefix validation still fails closed before persistence. *)
    (match
       Keeper_replay_prefix.split
         ~prefix:history_messages
         checkpoint.Agent_sdk.Checkpoint.messages
     with
     | Ok (_ :: _) ->
       Ok
         ( { checkpoint with
             Agent_sdk.Checkpoint.session_id
           }
         , None )
     | Ok [] ->
       Error
         "refusing to save recovery-control checkpoint without a current-turn \
          replay suffix"
     | Error _ ->
       Error
         "refusing to save recovery-control checkpoint: messages do not match \
          pre-turn history prefix")
  | Runtime_agent.TurnLimitObserved _
  | Runtime_agent.ExecutionTimeoutObserved _
  | Runtime_agent.ExecutionIdleTimeoutObserved _ ->
    (* An execution-limit observation has no lifecycle authority, but its OAS
       checkpoint is still the replay SSOT. Preserve the full typed message
       suffix (thinking, tool call, and tool result blocks) so the next cycle
       cannot repeat already committed tools after a blank terminal payload. *)
    observation_replay_checkpoint ~history_messages ~session_id checkpoint
  | ( Runtime_agent.Completed
    | Runtime_agent.Yielded_to_chat_waiting _
    | Runtime_agent.Yielded_to_durable_stimulus _ ) ->
    canonical_success_replay_checkpoint
      ~history_messages
      ~session_id
      ~response_text
      checkpoint
;;

module For_testing = struct
  let replay_suffix_prune_reason_to_string =
    replay_suffix_prune_reason_to_string

  let checkpoint_for_replay_persistence = checkpoint_for_replay_persistence
  let replay_response_text_for_capture = replay_response_text_for_capture

  let wire_capture_response_suppression_reasons =
    wire_capture_response_suppression_reasons

  let wire_capture_response_suppression_reason_label =
    wire_capture_response_suppression_reason_label

  let emit_wire_capture_response_suppressed_metrics =
    emit_wire_capture_response_suppressed_metrics

end

let finalize
    ~config
    ~meta
    ~generation
    ~manifest_keeper_turn_id
    ~session
    ~(append_manifest : Keeper_agent_run_turn_helpers.append_manifest_fn)
    ~model
    ~(acc : Keeper_run_tools.hook_accumulator)
    ~actual_keeper_tool_names
    ~(result : Runtime_agent.run_result)
    ~checkpoint_persistence_error
    ~post_turn_t0
    ~runtime_id_string
    ~history_messages
    ~pre_turn_working_context
    ~prompt_metrics
    ~ctx_composition
    ~usage
    ~receipt_response_text_present_ref
    ~history_assistant_source
    ~pre_dispatch_compacted
    ~pre_dispatch_compaction_trigger
    ~pre_dispatch_compaction_before_tokens
    ~pre_dispatch_compaction_after_tokens
    ~raw_response_text
    ~capture_replay_response
    ?continuation_delivery_channel:_
    () =
  let completion_contract_result = acc.receipt_completion_contract_result in
  let control_checkpoint =
    Keeper_agent_run_response_text.stop_reason_suppresses_visible_response
      result.stop_reason
  in
  let suppression_reasons =
    wire_capture_response_suppression_reasons ~control_checkpoint
  in
  let suppress_visible_response = suppression_reasons <> [] in
  let raw_response_text_present =
    String.trim raw_response_text <> ""
  in
  emit_wire_capture_response_suppressed_metrics
    ~keeper_name:meta.name
    suppression_reasons;
  let { Keeper_agent_run_response_text.response_text } =
    Keeper_agent_run_response_text.finalize
      ~completion_contract_result
      ~stop_reason:result.stop_reason
      ~raw_response_text
      ~suppress_response_text:suppress_visible_response
      ()
  in
  receipt_response_text_present_ref := raw_response_text_present;
  let replay_response_text =
    replay_response_text_for_capture ~suppress_visible_response ~response_text
  in
  let assistant_msg =
    Option.map
      (fun replay_response_text ->
         Agent_sdk.Types.make_message
           ~role:Agent_sdk.Types.Assistant
           [ Agent_sdk.Types.Text replay_response_text ])
      replay_response_text
  in
  (match replay_response_text, assistant_msg with
   | Some response_text, Some assistant_msg ->
     Keeper_context_runtime.persist_message
       ~source:history_assistant_source
       session
       assistant_msg;
     capture_replay_response ~response_text
   | _ -> ());
  let saved_checkpoint_result =
    match result.checkpoint with
    | Some checkpoint ->
      let checkpoint_for_save_result =
        checkpoint_for_replay_persistence
          ~history_messages
          ~pre_turn_working_context
          ~completion_contract_result
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
         (match
            Keeper_checkpoint_store.save_oas_classified
              ~session_dir:session.session_dir
              patched
          with
       | Ok (Keeper_checkpoint_store.Saved _) ->
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
                     `String (replay_suffix_prune_reason_to_string reason)
                   | None -> `Null) );
                ( "completion_contract_result"
                , `String
                    (Keeper_execution_receipt
                      .completion_contract_result_to_string
                        completion_contract_result) );
               ])
           Keeper_runtime_manifest.Checkpoint_saved;
         Ok (Some patched)
       | Ok (Keeper_checkpoint_store.Stale_noop
                { incoming_turn_count; known_turn_count }) ->
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
    | None ->
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
  match saved_checkpoint_result with
  | Error e -> Error e
  | Ok saved_checkpoint ->
    (* Retired proof-ledger evaluation is absent. Task completion judgment is
       owned by the configured LLM reviewer at the Task boundary. *)
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
      ~response_text
      ~actual_tools:actual_keeper_tool_names
      ~librarian_messages
      ~post_turn_t0
      ~runtime_id:runtime_id_string
      ~inference_telemetry:result.response.telemetry
      ();
    Ok
      { response_text
      ; model_used = model
      ; prompt_metrics
      ; ctx_composition
      ; runtime_observation = result.runtime_observation
      ; turn_count = result.turns
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
      ; pre_dispatch_compacted
      ; pre_dispatch_compaction_trigger
      ; pre_dispatch_compaction_before_tokens
      ; pre_dispatch_compaction_after_tokens
      }
;;
