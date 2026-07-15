open Keeper_meta_contract
type success =
  { recovery : Keeper_context_runtime.overflow_retry_recovery
  ; manifest : (unit, string) result
  }
type failure =
  | Lifecycle of string * bool * Keeper_context_runtime.lifecycle_dispatch_error
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
let primary_max_context meta =
  let min_context = Keeper_config.min_keeper_context_tokens in
  let resolution = Keeper_context_runtime.resolve_max_context_resolution_of_meta meta in
  max min_context resolution.effective_budget
;;
let append_manifest ~config ~base_dir ~(meta : keeper_meta) recovery =
  match recovery.Keeper_context_runtime.compaction.trigger with
  | None -> Error "manual compaction completed without its typed trigger"
  | Some trigger ->
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let context : Keeper_runtime_manifest.turn_context =
      { manifest_keeper_name = meta.name
      ; manifest_agent_name = Some meta.agent_name
      ; manifest_trace_id = trace_id
      ; manifest_generation = Some recovery.turn_generation
      ; manifest_keeper_turn_id = Some recovery.checkpoint.turn_count
      }
    in
    let checkpoint_path =
      Keeper_checkpoint_store.oas_checkpoint_path
        ~session_dir:(Filename.concat base_dir recovery.checkpoint.session_id)
        ~session_id:recovery.checkpoint.session_id
    in
    let clock_refs =
      Keeper_runtime_manifest.clock_refs_for_context
        context
        ~event:Keeper_runtime_manifest.Context_compacted
        ~compaction_source:"operator_manual"
        ()
    in
    Keeper_runtime_manifest.make_for_context
      context
      ~event:Keeper_runtime_manifest.Context_compacted
      ?runtime_id:recovery.evidence.selected_runtime_id
      ~status:"compacted"
      ~decision:
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs
           (Keeper_runtime_manifest.with_payload_role
              ~payload_role:Keeper_runtime_manifest.Checkpoint
              (`Assoc
                [ "trigger", `String (Compaction_trigger.to_label trigger)
                ; "trigger_detail", Compaction_trigger.to_detail_json trigger
                ; ( "exact_evidence"
                  , Keeper_compact_policy.compaction_evidence_to_json recovery.evidence )
                ])))
      ~checkpoint_path
      ()
    |> Keeper_runtime_manifest.append config
;;
let run ~(config : Workspace.config) ~(meta : keeper_meta) =
  let dispatch stage event =
    Keeper_context_runtime.dispatch_keeper_phase_event_result
      ~config
      ~origin:Keeper_registry.Operator_compact
      ~keeper_name:meta.name
      event
    |> Result.map_error (fun error ->
      Lifecycle (stage, false, error))
  in
  let dispatch_failed reason =
    Keeper_context_runtime.dispatch_keeper_phase_event_result
      ~config
      ~origin:Keeper_registry.Operator_compact
      ~keeper_name:meta.name
      (Keeper_state_machine.Compaction_failed { reason })
  in
  match dispatch "operator_request" Keeper_state_machine.Operator_compact_requested with
  | Error _ as error -> error
  | Ok () ->
    (match dispatch "compaction_started" Keeper_state_machine.Compaction_started with
     | Error _ as error ->
       dispatch_failed "compaction_start_rejected" |> ignore;
       error
     | Ok () ->
       let base_dir = Keeper_types_profile.session_base_dir config in
       (match
          Keeper_context_runtime.recover_latest_checkpoint_for_overflow_retry
            ~base_dir
            ~meta
            ~trigger:Compaction_trigger.Manual
            ~primary_model_max_tokens:(primary_max_context meta)
        with
        | Error error ->
          let failure_dispatch =
            dispatch_failed (Keeper_post_turn.compaction_recovery_error_to_tag error)
          in
          Error (Recovery (error, failure_dispatch))
        | Ok recovery ->
          let manifest = append_manifest ~config ~base_dir ~meta recovery in
          (match
             Keeper_context_runtime.dispatch_compaction_completed
               ~config
               ~keeper_name:meta.name
               ~origin:Keeper_registry.Operator_compact
           with
           | Error error ->
             Error (Lifecycle ("compaction_completed", true, error))
           | Ok () -> Ok { recovery; manifest })))
;;

let failure_to_string = function
  | Lifecycle (stage, checkpoint_applied, error) ->
    Printf.sprintf
      "stage=%s checkpoint_applied=%b error=%s"
      stage
      checkpoint_applied
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
  | Recovery (error, _) -> Keeper_post_turn.compaction_recovery_error_to_string error
;;

let observe_manifest ~keeper_name = function
  | Ok () -> ()
  | Error detail ->
    Log.Keeper.error
      ~keeper_name
      "manual compaction manifest append failed after durable checkpoint: %s"
      detail;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ "keeper", keeper_name; "phase", "manual_compaction_manifest" ]
      ()
;;
