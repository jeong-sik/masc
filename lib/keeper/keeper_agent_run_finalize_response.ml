(** Keeper_agent_run_finalize_response — Process provider text and finalize turn.

    Extracted from [Keeper_agent_run.run_turn]. Handles response text
    finalization, sidecar persistence, checkpoint saving, contract-verification proof
    evaluation, post-turn memory, and result construction. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_result

let reported_state_snapshot_from_checkpoint
    (checkpoint : Agent_sdk.Checkpoint.t option)
  : Keeper_memory_policy.keeper_state_snapshot option =
  (* keeper_report_state tool removed — state reporting uses [STATE] text
     blocks parsed by Keeper_memory_policy elsewhere. *)
  ignore (checkpoint : Agent_sdk.Checkpoint.t option);
  None

let completion_contract_drops_current_turn_replay
    (completion_contract_result :
       Keeper_execution_receipt.completion_contract_result)
  =
  Keeper_execution_receipt.completion_contract_result_requires_attention
    completion_contract_result
;;

type replay_suffix_prune_reason =
  | Completion_contract_requires_attention
  | Synthetic_empty_state_snapshot
  | Canonical_success_replay

let replay_suffix_prune_reason_to_string = function
  | Completion_contract_requires_attention ->
    "completion_contract_requires_attention"
  | Synthetic_empty_state_snapshot -> "synthetic_empty_state_snapshot"
  | Canonical_success_replay -> "canonical_success_replay"
;;

let synthetic_empty_state_drops_current_turn_replay
      ~(state_snapshot_source : Keeper_memory_policy.state_snapshot_source)
      ~response_text
  =
  Keeper_memory_policy.state_snapshot_source_is_synthetic state_snapshot_source
  && String.trim response_text = ""
;;

let replay_suffix_prune_reason
      ~completion_contract_result
      ~state_snapshot_source
      ~response_text
  =
  if completion_contract_drops_current_turn_replay completion_contract_result
  then Some Completion_contract_requires_attention
  else if
    synthetic_empty_state_drops_current_turn_replay
      ~state_snapshot_source
      ~response_text
  then Some Synthetic_empty_state_snapshot
  else None
;;

let stop_reason_requests_resume_merge = function
  | Runtime_agent.TurnBudgetExhausted _ -> true
  | Runtime_agent.Completed | Runtime_agent.MutationBoundaryReached _ -> false
;;

let should_resume_merge
      ~pre_dispatch_compacted
      ~state_snapshot_source
      ~stop_reason
      ~completion_contract_result
  =
  if completion_contract_drops_current_turn_replay completion_contract_result
  then false
  else
    pre_dispatch_compacted
    || Keeper_memory_policy.state_snapshot_source_is_synthetic state_snapshot_source
    || stop_reason_requests_resume_merge stop_reason
;;

let rec messages_prefix_equal expected actual =
  match expected, actual with
  | [], _ -> true
  | expected_msg :: expected_rest, actual_msg :: actual_rest ->
    expected_msg = actual_msg && messages_prefix_equal expected_rest actual_rest
  | _ :: _, [] -> false
;;

let rec drop_prefix prefix messages =
  match prefix, messages with
  | [], rest -> rest
  | _ :: prefix_rest, _ :: message_rest -> drop_prefix prefix_rest message_rest
  | _ :: _, [] -> []
;;

let prune_current_turn_replay
      ~(history_messages : Agent_sdk.Types.message list)
      ~(pre_turn_working_context : Yojson.Safe.t option)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  if
    messages_prefix_equal history_messages checkpoint.Agent_sdk.Checkpoint.messages
    && List.length checkpoint.Agent_sdk.Checkpoint.messages > List.length history_messages
  then
    let messages =
      Keeper_context_core.repair_broken_tool_call_pairs history_messages
    in
    Some
      { checkpoint with
        Agent_sdk.Checkpoint.messages
      ; working_context = pre_turn_working_context
      }
  else None
;;

let canonical_success_replay_checkpoint
      ~(history_messages : Agent_sdk.Types.message list)
      ~(session_id : string)
      ~(response_text : string)
      ~(state_snapshot : Keeper_memory_policy.keeper_state_snapshot option)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  if messages_prefix_equal history_messages checkpoint.Agent_sdk.Checkpoint.messages
  then
    let dropped_current_turn_replay =
      List.length checkpoint.Agent_sdk.Checkpoint.messages
      > List.length history_messages
    in
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
          let current_suffix =
            drop_prefix history_messages checkpoint.Agent_sdk.Checkpoint.messages
          in
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
          ?snapshot:state_snapshot
    in
    Ok
      ( checkpoint
      , if dropped_current_turn_replay
        then Some Canonical_success_replay
        else None )
  else
    Error
      "refusing to save checkpoint: canonical replay persistence requires \
       checkpoint messages to match pre-turn history prefix"
;;

let checkpoint_for_replay_persistence
      ~(history_messages : Agent_sdk.Types.message list)
      ~(pre_turn_working_context : Yojson.Safe.t option)
      ~(completion_contract_result :
         Keeper_execution_receipt.completion_contract_result)
      ~(session_id : string)
      ~(response_text : string)
      ~(state_snapshot_source : Keeper_memory_policy.state_snapshot_source)
      ~(state_snapshot : Keeper_memory_policy.keeper_state_snapshot option)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  match
    replay_suffix_prune_reason
      ~completion_contract_result
      ~state_snapshot_source
      ~response_text
  with
  | Some reason ->
    let pruned =
      prune_current_turn_replay
        ~history_messages
        ~pre_turn_working_context
        checkpoint
    in
    (match pruned with
    | Some checkpoint -> Ok (checkpoint, Some reason)
    | None ->
      Error
        (Printf.sprintf
           "refusing to save checkpoint: replay suffix prune reason=%s but \
            checkpoint messages do not match pre-turn history prefix"
           (replay_suffix_prune_reason_to_string reason)))
  | None ->
    canonical_success_replay_checkpoint
      ~history_messages
      ~session_id
      ~response_text
      ~state_snapshot
      checkpoint
;;

module For_testing = struct
  let completion_contract_drops_current_turn_replay =
    completion_contract_drops_current_turn_replay

  let completion_contract_suppresses_visible_response =
    Keeper_agent_run_response_text.completion_contract_suppresses_visible_response

  let replay_suffix_prune_reason_to_string =
    replay_suffix_prune_reason_to_string

  let checkpoint_for_replay_persistence = checkpoint_for_replay_persistence
  let should_resume_merge = should_resume_merge
end

let finalize
    ~config
    ~meta
    ~generation
    ~manifest_keeper_turn_id
    ~trace_id
    ~session
    ~(append_manifest : Keeper_agent_run_sidecar.append_manifest_fn)
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
    () =
  let budget_exhausted =
    Keeper_agent_run_response_text.stop_reason_is_turn_budget_exhausted
      result.stop_reason
  in
  let completion_contract_result = acc.receipt_completion_contract_result in
  let contract_suppresses_visible_response =
    Keeper_agent_run_response_text.completion_contract_suppresses_visible_response
      ~history_assistant_source
      completion_contract_result
  in
  let suppress_visible_response =
    budget_exhausted || contract_suppresses_visible_response
  in
  let raw_response_text_present =
    (not budget_exhausted) && String.trim raw_response_text <> ""
  in
  if contract_suppresses_visible_response && raw_response_text_present
  then
    Log.Keeper.info ~keeper_name:meta.name
      "suppressing keeper-visible response for completion_contract_result=%s"
      (Keeper_execution_receipt.completion_contract_result_to_string
         completion_contract_result);
  let reported_state_snapshot =
    reported_state_snapshot_from_checkpoint result.checkpoint
  in
  let
    { Keeper_agent_run_response_text.state_snapshot
    ; state_snapshot_source
    ; response_text
    }
    =
    Keeper_agent_run_response_text.finalize
      ~reported_state_snapshot
      ~keeper_name:meta.name
      ~goal:meta.goal
      ~actual_keeper_tool_names
      ~completion_contract_result
      ~stop_reason:result.stop_reason
      ~raw_response_text
      ~suppress_response_text:suppress_visible_response
      ()
  in
  (* Gate the working-state resume merge (ResumeFromDigest) to turns where active
     loops can be silently lost: a pre-dispatch compaction may have dropped the
     reminder, or the model emitted no structured state at all (synthesized). On
     a normal model-authored state turn the snapshot is authoritative, so a
     dropped loop still clears. *)
  let resume_merge =
    should_resume_merge
      ~pre_dispatch_compacted
      ~state_snapshot_source
      ~stop_reason:result.stop_reason
      ~completion_contract_result
  in
  let { Keeper_agent_run_sidecar.working_state = _
      ; state_snapshot_saved = _
      ; working_state_saved = _
      } =
    Keeper_agent_run_sidecar.save_sidecars
      ~keeper_name:meta.name
      ~agent_name:meta.agent_name
      ~trace_id
      ~generation
      ~keeper_turn_id:manifest_keeper_turn_id
      ~oas_turn_count:result.turns
      ~session_dir:session.session_dir
      ~state_snapshot
      ~state_snapshot_source
      ~resume_merge
    ~append_manifest
    ()
  in
  receipt_response_text_present_ref := raw_response_text_present;
  let assistant_msg =
    if suppress_visible_response || String.trim response_text = ""
    then None
    else
      Some
        (Agent_sdk.Types.make_message
           ~role:Agent_sdk.Types.Assistant
           ~metadata:
             [ ( Keeper_memory_policy.replay_metadata_key
               , Keeper_memory_policy.replay_metadata_of_snapshot
                   state_snapshot )
             ]
           [ Agent_sdk.Types.Text response_text ])
  in
  Option.iter
    (Keeper_context_runtime.persist_message
       ~source:history_assistant_source
       session)
    assistant_msg;
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
          ~state_snapshot_source
          ~state_snapshot:(Some state_snapshot)
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
    (* Contract-verification proof evaluation / verdict-ledger persistence removed: task/goal
       completion is verified by [Cdal_evidence_gate] (evidence-substantiveness),
       not by an internal proof/verdict pipeline. *)
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
      ~state_snapshot
      ~state_snapshot_source
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
