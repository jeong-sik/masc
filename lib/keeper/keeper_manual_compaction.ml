open Keeper_meta_contract
type success =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; manifest : (unit, string) result
  }

type operation_outcome =
  | Compacted of success
  | No_compaction of Keeper_post_turn.no_compaction

type lifecycle_stage =
  | Operator_request
  | Compaction_started
  | Compaction_completed

type failure =
  | Lifecycle of
      { stage : lifecycle_stage
      ; checkpoint_applied : bool
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      }
  | Lifecycle_with_failure_dispatch of
      { stage : lifecycle_stage
      ; checkpoint_applied : bool
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
let append_manifest ~config ~base_dir ~(meta : keeper_meta) recovery =
  let trigger = recovery.Keeper_context_runtime.trigger in
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
      ~runtime_id:recovery.evidence.selected_runtime_id
      ~status:"compacted"
      ~decision:
        (Keeper_runtime_manifest.with_clock_refs
           ~clock_refs
           (Keeper_runtime_manifest.with_payload_role
              ~payload_role:Keeper_runtime_manifest.Checkpoint
              (`Assoc
                [ "trigger", `String (Compaction_trigger.to_label trigger)
                ; "trigger_detail", Compaction_trigger.to_detail_json trigger
                ; ( Keeper_compaction_evidence.exact_evidence_key
                  , Keeper_compaction_evidence.to_json recovery.evidence )
                ])))
      ~checkpoint_path
      ()
    |> Keeper_runtime_manifest.append config
;;
let dispatch_event ~config ~meta event =
  Keeper_context_runtime.dispatch_keeper_phase_event_result
    ~config
    ~origin:Keeper_registry.Operator_compact
    ~keeper_name:meta.name
    event
;;

let dispatch_failed ~config ~meta reason =
  Keeper_context_runtime.dispatch_keeper_phase_event_result
    ~config
    ~origin:Keeper_registry.Operator_compact
    ~keeper_name:meta.name
    (Keeper_state_machine.Compaction_failed { reason })
;;

let run_start_lifecycle ~config ~meta =
  match dispatch_event ~config ~meta Keeper_state_machine.Operator_compact_requested with
  | Error error ->
    Error (Lifecycle { stage = Operator_request; checkpoint_applied = false; error })
  | Ok () ->
    (match dispatch_event ~config ~meta Keeper_state_machine.Compaction_started with
     | Error error ->
       let failure_dispatch = dispatch_failed ~config ~meta "compaction_start_rejected" in
       Error
         (Lifecycle_with_failure_dispatch
            { stage = Compaction_started
            ; checkpoint_applied = false
            ; error
            ; failure_dispatch
            })
     | Ok () -> Ok ())
;;

let run_commit ~config ~base_dir ~meta prepared =
  match Keeper_context_runtime.commit_prepared_compaction ~meta prepared with
  | Error error ->
    let failure_dispatch =
      dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
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
       Error
         (Lifecycle
            { stage = Compaction_completed
            ; checkpoint_applied = true
            ; error
            })
     | Ok () ->
       Keeper_unified_metrics.broadcast_compaction
         ~name:meta.name
         recovery;
       Ok (Compacted { recovery; manifest }))
;;

let run ~(config : Workspace.config) ~(meta : keeper_meta) =
  (* Synchronous composition (kept for API stability): start lifecycle,
     prepare (load + policy + LLM), commit — all inline. *)
  match run_start_lifecycle ~config ~meta with
  | Error _ as error -> error
  | Ok () ->
    let base_dir = Keeper_types_profile.session_base_dir config in
    (match
       Keeper_context_runtime.prepare_compaction
         ~base_dir
         ~meta
         ~trigger:Compaction_trigger.Manual
     with
     | Error (Keeper_post_turn.No_compaction no_compaction as error) ->
       let failure_dispatch =
         dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
       in
       (match failure_dispatch with
        | Ok () -> Ok (No_compaction no_compaction)
        | Error _ -> Error (Recovery (error, failure_dispatch)))
     | Error error ->
       let failure_dispatch =
         dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
       in
       Error (Recovery (error, failure_dispatch))
     | Ok prepared -> run_commit ~config ~base_dir ~meta prepared)
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

let run_admitted ~(config : Workspace.config) ~(meta : keeper_meta) =
  (* The provider call (prepare) runs outside the keeper admission so the
     lane stays runnable while the LLM works; the lifecycle start, the
     source-CAS commit, the manifest and the completion dispatch stay
     inside it.  Two short admission sections replace the old full-run
     hold — correctness between them is enforced by the source CAS, not
     by the slot. *)
  match
    Keeper_turn_admission.run_compaction_if_free
      ~base_path:config.base_path
      ~keeper_name:meta.name
      (fun () -> run_start_lifecycle ~config ~meta)
  with
  | `Busy block -> `Busy block
  | `Ran (Error failure) -> `Compaction_failed failure
  | `Ran (Ok ()) ->
    let base_dir = Keeper_types_profile.session_base_dir config in
    (match
       Keeper_context_runtime.prepare_compaction
         ~base_dir
         ~meta
         ~trigger:Compaction_trigger.Manual
     with
     | Error (Keeper_post_turn.No_compaction no_compaction as error) ->
       (match
          Keeper_turn_admission.run_compaction_if_free
            ~base_path:config.base_path
            ~keeper_name:meta.name
            (fun () ->
              dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error))
        with
        | `Busy block -> `Busy block
        | `Ran (Ok ()) -> `No_compaction no_compaction
        | `Ran (Error failure) -> `Compaction_failed (Recovery (error, Error failure)))
     | Error error ->
       (match
          Keeper_turn_admission.run_compaction_if_free
            ~base_path:config.base_path
            ~keeper_name:meta.name
            (fun () ->
              let failure_dispatch =
                dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
              in
              Recovery (error, failure_dispatch))
        with
        | `Busy block -> `Busy block
        | `Ran failure -> `Compaction_failed failure)
     | Ok prepared ->
       (match
          Keeper_turn_admission.run_compaction_if_free
            ~base_path:config.base_path
            ~keeper_name:meta.name
            (fun () -> run_commit ~config ~base_dir ~meta prepared)
        with
        | `Busy block -> `Busy block
        | `Ran (Error failure) -> `Compaction_failed failure
        | `Ran (Ok (Compacted success)) ->
          observe_manifest ~keeper_name:meta.name success.manifest;
          `Applied success
        | `Ran (Ok (No_compaction no_compaction)) -> `No_compaction no_compaction))
;;

let lifecycle_stage_to_string = function
  | Operator_request -> "operator_request"
  | Compaction_started -> "compaction_started"
  | Compaction_completed -> "compaction_completed"
;;

let failure_dispatch_to_string = function
  | Ok () -> "applied"
  | Error error ->
    "rejected:" ^ Keeper_context_runtime.lifecycle_dispatch_error_to_string error
;;

let failure_to_string = function
  | Lifecycle { stage; checkpoint_applied; error } ->
    Printf.sprintf
      "stage=%s checkpoint_applied=%b error=%s"
      (lifecycle_stage_to_string stage)
      checkpoint_applied
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
  | Lifecycle_with_failure_dispatch
      { stage; checkpoint_applied; error; failure_dispatch } ->
    Printf.sprintf
      "stage=%s checkpoint_applied=%b error=%s failure_dispatch=%s"
      (lifecycle_stage_to_string stage)
      checkpoint_applied
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
      (failure_dispatch_to_string failure_dispatch)
  | Recovery (error, failure_dispatch) ->
    Printf.sprintf
      "recovery_error=%s failure_dispatch=%s"
      (Keeper_post_turn.compaction_recovery_error_to_string error)
      (failure_dispatch_to_string failure_dispatch)
;;




