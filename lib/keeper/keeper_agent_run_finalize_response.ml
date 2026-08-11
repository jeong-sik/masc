(** Keeper_agent_run_finalize_response — Process provider text and finalize turn.

    Extracted from [Keeper_agent_run.run_turn]. Handles response text
    finalization, checkpoint saving, contract-verification proof
    evaluation, post-turn memory, and result construction. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_result

let precommit_continuation_delivery_intent ~config = function
  | None -> Ok None
  | Some intent ->
    (match Keeper_continuation_delivery_store.persist ~config intent with
     | Ok _ -> Ok (Some intent)
     | Error
         (Keeper_continuation_delivery_store.Persistence_failed
           { publication = Keeper_continuation_delivery_store.Published_indeterminate
           ; detail
           }) ->
       (* A durable rename may have completed even though its directory fsync
          did not.  Accept only an exact final record; a missing, unreadable,
          or conflicting record remains an explicit precommit failure. *)
       (match
          Keeper_continuation_delivery_store.load
            ~config
            ~keeper_name:intent.keeper_name
            ~intent_id:intent.intent_id
        with
        | Ok recovered
          when Yojson.Safe.equal
                 (Keeper_continuation_delivery_intent.to_yojson recovered)
                 (Keeper_continuation_delivery_intent.to_yojson intent) ->
          Ok (Some recovered)
        | Ok _ ->
          Error
            (Keeper_continuation_delivery_store.Identity_conflict
               "indeterminate precommit recovered different immutable content")
        | Error recovery_error ->
          Error
            (Keeper_continuation_delivery_store.Persistence_failed
               { publication =
                   Keeper_continuation_delivery_store.Published_indeterminate
               ; detail =
                   detail
                   ^ "; exact precommit recovery failed: "
                   ^ Keeper_continuation_delivery_store.error_to_string
                       recovery_error
               }))
     | Error error -> Error error)
;;

let finalize
    ~config
    ~meta
    ~publication_recovery
    ~ctx_snapshot
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
    ~final_agent_core_turn_ordinal
    ~checkpoint_persistence_error
    ~post_turn_t0
    ~runtime_id_string
    ~max_context
    ~checkpoint_owner
    ~history_messages
    ~prompt_metrics
    ~ctx_composition
    ~usage
    ~receipt_response_text_present_ref
    ~history_assistant_source
    ~raw_response_text
    ~turn_outcome
    ~terminal_effect_receipt
    ~capture_replay_response
    ?continuation_channel
    ?continuation_delivery_origin
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
  let ( let* ) = Result.bind in
  let* continuation_delivery_intent =
    continuation_delivery_intent_for_result
      ~keeper_name:meta.name
      ~keeper_turn_id:manifest_keeper_turn_id
      ~origin:continuation_delivery_origin
      ~response_text
      ~turn_outcome
    |> Result.map_error (fun error ->
      Agent_core.Error.Internal
        ("continuation delivery intent construction failed: "
         ^ Keeper_continuation_delivery_intent.error_to_string error))
  in
  (* The source remains replay-visible until the unified turn commits its
     delivery settlement.  Commit the deterministic Pending outbox record
     before assistant history or checkpoint finalization, so a crash at any
     later boundary is recovered by [settle_existing] instead of rerunning
     inference and tool effects for the same source. *)
  let* continuation_delivery_intent =
    precommit_continuation_delivery_intent
      ~config
      continuation_delivery_intent
    |> Result.map_error (fun error ->
      Agent_core.Error.Internal
        ("continuation delivery outbox precommit failed before response finalization: "
         ^ Keeper_continuation_delivery_store.error_to_string error))
  in
  receipt_response_text_present_ref := raw_response_text_present;
  let assistant_msg =
    Keeper_replay_checkpoint.consume_replay_response
      ~suppress_visible_response
      ~response_text
      ~consume:(fun ~response_text ->
        let assistant_msg =
          Agent_core.Types.make_message
           ~role:Agent_core.Types.Assistant
           [ Agent_core.Types.Text response_text ]
        in
        Keeper_context_runtime.persist_message
          ~source:history_assistant_source
          session
          assistant_msg;
        capture_replay_response ~response_text;
        assistant_msg)
  in
  let save_agent_core_checkpoint result_checkpoint =
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
             Keeper_checkpoint_store.save_agent_core_classified
               ~session_dir:session.session_dir
               patched
             |> Result.map (fun outcome -> `Written outcome)
         in
         (match save_outcome with
       | Ok `Reused
       | Ok (`Written (Keeper_checkpoint_store.Saved _)) ->
         append_manifest ~site:"checkpoint_saved"
           ~keeper_turn_id:manifest_keeper_turn_id
           ~agent_core_turn_count:result.turns
           ~checkpoint_path:
             (Keeper_checkpoint_store.agent_core_checkpoint_path
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
           "runtime=%s AGENT_CORE checkpoint stale no-op: incoming turn_count=%d, last saved=%d"
           runtime_id_string
           incoming_turn_count known_turn_count;
         Otel_metric_store.inc_counter
           "masc_keeper_checkpoint_stale_noop_total"
           ~labels:[ "keeper", meta.name; "site", "finalize" ]
           ();
         Ok None
       | Error e ->
         Log.Keeper.error ~keeper_name:meta.name
           "runtime=%s AGENT_CORE checkpoint save failed: %s"
           runtime_id_string
           e;
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string CheckpointFailures)
           ~labels:[ "keeper", meta.name; "site", "save" ]
           ();
         Error
           (checkpoint_persistence_error
              ~keeper_name:meta.name
              ~detail:("AGENT_CORE checkpoint save failed: " ^ e))))
  in
  let missing_agent_core_checkpoint () =
      Log.Keeper.error ~keeper_name:meta.name
        "runtime=%s missing AGENT_CORE checkpoint after run"
        runtime_id_string;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CheckpointFailures)
        ~labels:[ "keeper", meta.name; "site", "missing" ]
        ();
      Error
        (checkpoint_persistence_error
           ~keeper_name:meta.name
           ~detail:"missing AGENT_CORE checkpoint after run")
  in
  let unexpected_agent_core_checkpoint () =
    Log.Keeper.error ~keeper_name:meta.name
      "runtime=%s official-client runtime returned an AGENT_CORE checkpoint"
      runtime_id_string;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[ "keeper", meta.name; "site", "owner_mismatch" ]
      ();
    Error
      (checkpoint_persistence_error
         ~keeper_name:meta.name
         ~detail:"official-client runtime returned an AGENT_CORE checkpoint")
  in
  let saved_checkpoint_result =
    match checkpoint_owner, result.checkpoint with
    | Runtime_execution.Masc_agent_core, Some result_checkpoint ->
      save_agent_core_checkpoint result_checkpoint
    | Runtime_execution.Masc_agent_core, None -> missing_agent_core_checkpoint ()
    | Runtime_execution.Official_client, Some _ ->
      unexpected_agent_core_checkpoint ()
    | Runtime_execution.Official_client, None -> Ok None
  in
  let* saved_checkpoint = saved_checkpoint_result in
    (* Retired proof-ledger evaluation is absent. Strict Task completion
       judgment is owned by the authenticated operator or typed judge
       boundary. *)
    let librarian_messages =
      match saved_checkpoint with
      | Some checkpoint -> checkpoint.Agent_core.Checkpoint.messages
      | None -> Option.to_list assistant_msg
    in
    Keeper_agent_run_post_turn_memory.run
      ~config
      ~meta
      ~generation
      ~turn:manifest_keeper_turn_id
      ~agent_core_turn_count:result.turns
      ~actual_tools:actual_keeper_tool_names
      ~librarian_messages
      ~post_turn_t0
      ~inference_telemetry:result.response.telemetry
      ();
    Ok
      { response_text
      ; turn_outcome
      ; continuation_delivery_intent
      ; terminal_effect_receipt
      ; model_used = model
      ; runtime_id = runtime_id_string
      ; max_context
      ; prompt_metrics
      ; ctx_composition
      ; runtime_observation = result.runtime_observation
      ; turn_count = result.turns
      ; final_agent_core_turn_ordinal
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
