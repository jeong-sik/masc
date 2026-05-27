(** Keeper_agent_run_finalize_response — Process provider text and finalize turn.

    Extracted from [Keeper_agent_run.run_turn]. Handles response text
    finalization, sidecar persistence, checkpoint saving, CDAL proof
    evaluation, post-turn memory, and result construction. *)

open Keeper_types
open Keeper_agent_result

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
    ~memory
    ~actual_keeper_tool_names
    ~actual_keeper_tool_names_ref
    ~(result : Cascade_runner.run_result)
    ~checkpoint_persistence_error
    ~proof_ref
    ~post_turn_t0
    ?provider_filter
    ~cascade_name_string
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
  let
    { Keeper_agent_run_response_text.state_snapshot; response_text }
    =
    Keeper_agent_run_response_text.finalize
      ~keeper_name:meta.name
      ~goal:meta.goal
      ~actual_keeper_tool_names:!actual_keeper_tool_names_ref
      ~fallback_tool_names:actual_keeper_tool_names
      ~stop_reason:result.stop_reason
      ~raw_response_text
  in
  let state_snapshot_source =
    if
      Option.is_some
        (Keeper_memory_policy.parse_state_snapshot_from_reply
           raw_response_text)
    then "model_state_block"
    else "synthesized"
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
      ~append_manifest
      ()
  in
  receipt_response_text_present_ref := true;
  let assistant_msg =
    Agent_sdk.Types.make_message
      ~role:Agent_sdk.Types.Assistant
      ~metadata:
        [ ( Keeper_memory_policy.replay_metadata_key
          , Keeper_memory_policy.replay_metadata_of_snapshot
              state_snapshot )
        ]
      [ Agent_sdk.Types.Text response_text ]
  in
  Keeper_context_runtime.persist_message
    ~source:history_assistant_source
    session
    assistant_msg;
  let saved_checkpoint_result =
    match result.checkpoint with
    | Some checkpoint ->
      let patched =
        Keeper_context_core.patch_checkpoint_last_assistant
          checkpoint
          ~session_id:
            (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~response_text
          ~snapshot:state_snapshot
      in
      (match
         Keeper_checkpoint_store.save_oas
           ~session_dir:session.session_dir
           patched
       with
       | Ok () ->
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
               ])
           Keeper_runtime_manifest.Checkpoint_saved;
         Ok (Some patched)
       | Error e ->
         Log.Keeper.error
           "keeper:%s cascade=%s OAS checkpoint save failed: %s"
           meta.name
           (Keeper_types.cascade_name_of_meta meta)
           e;
         Prometheus.inc_counter
           Keeper_metrics.(to_string CheckpointFailures)
           ~labels:[ "keeper", meta.name; "site", "save" ]
           ();
         Error
           (checkpoint_persistence_error
              ~keeper_name:meta.name
              ~detail:("OAS checkpoint save failed: " ^ e)))
    | None ->
      Log.Keeper.error
        "keeper:%s cascade=%s missing OAS checkpoint after run"
        meta.name
        (Keeper_types.cascade_name_of_meta meta);
      Prometheus.inc_counter
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
    (match
       Keeper_agent_run_turn_helpers.select_cdal_proof
         ~result_proof:result.proof
         ~captured_proof:!proof_ref
     with
     | Some p ->
       Keeper_turn_telemetry.log_keeper_proof ~keeper_name:meta.name p;
       let store = Masc_mcp_cdal_runtime.Proof_store.default_config in
       let outcome = Cdal_eval_v1.evaluate ~store p in
       let verdict = Cdal_eval_v1.verdict_of_outcome outcome in
       let current_task_id =
         Option.map
           Keeper_id.Task_id.to_string
           acc.meta.current_task_id
       in
       let task_id =
         Keeper_agent_run_contract_helpers.cdal_task_id_for_verdict
           ~current_task_id
           ~tool_calls:acc.tool_calls
       in
       let task_subject =
         Option.map
           (fun task_id ->
              Coord_hooks.{ kind = "task"; id = task_id })
           task_id
       in
       let emit_keeper_activity ~kind ~payload ~tags =
         try
           (Atomic.get Coord_hooks.activity_emit_fn)
             config
             ~actor:
               Coord_hooks.{ kind = "agent"; id = meta.agent_name }
             ?subject:task_subject
             ~kind
             ~payload
             ~tags
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Prometheus.inc_counter
             Keeper_metrics.(to_string DispatchEventFailures)
             ~labels:[ "keeper", meta.name; "site", "activity_emit" ]
             ();
           Log.Keeper.warn
             "keeper:%s activity emit failed (%s): %s"
             meta.name
             kind
             (Printexc.to_string exn)
       in
       (match Keeper_agent_run_contract_helpers.cdal_verdict_persist_decision task_id with
        | `Persist_task_scoped task_id ->
          Cdal_eval_v1.persist ~task_id verdict
        | `Skip_missing_task_scope ->
          Log.Keeper.debug
            "keeper:%s contract_verdict not persisted to task \
             gate ledger: missing task_id/current_task_id"
            meta.name);
       Keeper_turn_telemetry.log_keeper_contract_verdict
         ~keeper_name:meta.name
         verdict;
       emit_keeper_activity
         ~kind:"keeper.contract_verdict"
         ~payload:
           (Keeper_turn_telemetry.contract_verdict_activity_payload
              ~keeper_name:meta.name
              verdict)
         ~tags:
           ([ "keeper"
            ; "cdal"
            ; "contract_verdict"
            ; Cdal_types.contract_status_to_string verdict.status
            ]
            @
            if
              List.exists
                (fun (gap : Cdal_types.completeness_gap) ->
                   String.equal
                     gap.artifact
                     "evidence/review_warning.json")
                verdict.completeness_gaps
            then [ "review_requirement" ]
            else []);
       (match outcome with
        | Cdal_eval_v1.Load_failure (err, _) ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string DispatchEventFailures)
            ~labels:[ "keeper", meta.name; "site", "cdal_load" ]
            ();
          Log.Keeper.warn
            "keeper:%s contract_verdict load failure: %s"
            meta.name
            (Cdal_loader.load_error_to_string err)
        | Cdal_eval_v1.Verdict (_, _) -> ());
       (match Cdal_eval_v1.friction_of_outcome outcome with
        | Some fp ->
          Keeper_turn_telemetry.log_keeper_friction
            ~keeper_name:meta.name
            fp;
          emit_keeper_activity
            ~kind:"keeper.friction"
            ~payload:
              (Keeper_turn_telemetry.friction_activity_payload
                 ~keeper_name:meta.name
                 fp)
            ~tags:
              ([ "keeper"; "cdal"; "friction" ]
               @
               if fp.review_tripwires <> [] then [ "tripwire" ] else []
              )
        | None -> ())
     | None -> ());
    Keeper_agent_run_post_turn_memory.run
      ~config
      ~meta
      ~memory
      ~turn:manifest_keeper_turn_id
      ~oas_turn_count:result.turns
      ~response_text
      ~actual_tools:actual_keeper_tool_names
      ~state_snapshot
      ~post_turn_t0
      ?provider_filter
      ~cascade_name:cascade_name_string
      ~inference_telemetry:result.response.telemetry
      ();
    Ok
      { response_text
      ; model_used = model
      ; prompt_metrics
      ; ctx_composition
      ; cascade_observation = result.cascade_observation
      ; turn_count = result.turns
      ; tool_calls_made = List.length actual_keeper_tool_names
      ; usage
      ; usage_reported = Option.is_some result.response.usage
      ; tools_used = actual_keeper_tool_names
      ; tool_calls = List.rev acc.tool_calls
      ; checkpoint = saved_checkpoint
      ; proof = result.proof
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
