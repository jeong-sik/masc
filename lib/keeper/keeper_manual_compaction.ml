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

let observe_terminal_dispatch_failure ~meta = function
  | Ok () -> ()
  | Error error ->
    Log.Keeper.error
      ~keeper_name:meta.name
      "manual compaction terminal lifecycle dispatch failed without reopening the affine request: %s"
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
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
  match Keeper_context_runtime.commit_prepared_compaction prepared with
  | Error (Keeper_post_turn.No_compaction no_compaction as error) ->
    let failure_dispatch =
      dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
    in
    observe_terminal_dispatch_failure ~meta failure_dispatch;
    Ok (No_compaction no_compaction)
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
       Log.Keeper.error
         ~keeper_name:meta.name
         "manual compaction completion lifecycle dispatch failed after durable commit; request remains applied: %s"
         (Keeper_context_runtime.lifecycle_dispatch_error_to_string error);
       Keeper_unified_metrics.broadcast_compaction ~name:meta.name recovery;
       Ok (Compacted { recovery; manifest })
     | Ok () ->
       Keeper_unified_metrics.broadcast_compaction
         ~name:meta.name
         recovery;
       Ok (Compacted { recovery; manifest }))
;;

let finish_preparation ~config ~base_dir ~meta = function
  | Error (Keeper_post_turn.No_compaction no_compaction as error) ->
    let failure_dispatch =
      dispatch_failed
        ~config
        ~meta
        (Keeper_post_turn.compaction_recovery_error_to_tag error)
    in
    observe_terminal_dispatch_failure ~meta failure_dispatch;
    Ok (No_compaction no_compaction)
  | Error error ->
    let failure_dispatch =
      dispatch_failed
        ~config
        ~meta
        (Keeper_post_turn.compaction_recovery_error_to_tag error)
    in
    Error (Recovery (error, failure_dispatch))
  | Ok prepared -> run_commit ~config ~base_dir ~meta prepared
;;

let prepare_with ~prepare_compaction ~config ~meta =
  let base_dir = Keeper_types_profile.session_base_dir config in
  let projection_request =
    Keeper_compaction_projection_target.request
      ~assignment_id:(runtime_id_of_meta meta)
      ~resolve_context_window:(fun runtime ->
        match
          Keeper_context_runtime.resolve_max_context_resolution_for_runtime
            ~requested_override:meta.max_context_override
            runtime
        with
        | Ok resolution ->
          Keeper_compaction_projection_target.Resolved_context_window
            resolution.effective_budget
        | Error (Invalid_requested_context_override value) ->
          Keeper_compaction_projection_target.Invalid_context_window value
        | Error (Runtime_context_window_unavailable _) ->
          Keeper_compaction_projection_target.Context_window_not_resolved)
  in
  ( base_dir
  , prepare_compaction
      ~base_dir
      ~meta
      ~trigger:Compaction_trigger.Manual
      ~projection_request )
;;

let prepare =
  prepare_with ~prepare_compaction:Keeper_context_runtime.prepare_compaction
;;

let no_compaction_after_prepared_cancellation prepared =
  Eio.Cancel.protect (fun () ->
    No_compaction
      (Keeper_post_turn.no_compaction_of_uncommitted_prepared
         ~cause:Keeper_event_queue_state.Execution_cancelled_after_dispatch
         prepared))
;;

let run ~(config : Workspace.config) ~(meta : keeper_meta) =
  (* Planning is outside the lifecycle. Only the deterministic lifecycle and
     source-CAS commit may set [compaction_active], and they close in this
     single synchronous section. *)
  let base_dir, preparation = prepare ~config ~meta in
  match preparation with
  | Ok prepared ->
    (try
       match run_start_lifecycle ~config ~meta with
       | Error _ ->
         Ok
           (No_compaction
              (Keeper_post_turn.no_compaction_of_uncommitted_prepared
                 ~cause:
                   Keeper_event_queue_state.Lifecycle_transition_failed_after_dispatch
                 prepared))
       | Ok () -> finish_preparation ~config ~base_dir ~meta preparation
     with
     | Eio.Cancel.Cancelled _ ->
       Ok (no_compaction_after_prepared_cancellation prepared))
  | Error (Keeper_post_turn.No_compaction no_compaction) ->
    (match run_start_lifecycle ~config ~meta with
     | Error _ -> Ok (No_compaction no_compaction)
     | Ok () -> finish_preparation ~config ~base_dir ~meta preparation)
  | (Error _ as failed_preparation) ->
    (match run_start_lifecycle ~config ~meta with
     | Error failure -> Error failure
     | Ok () -> finish_preparation ~config ~base_dir ~meta failed_preparation)
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

let preserve_no_compaction_after_final_admission_busy = function
  | Keeper_event_queue_state.Exact_execution_terminal _ -> true
  | Keeper_event_queue_state.Exact_lane_unconfigured
  | Keeper_event_queue_state.No_eligible_history
  | Keeper_event_queue_state.Invalid_structural_source
  | Keeper_event_queue_state.Structurally_unchanged
  | Keeper_event_queue_state.Checkpoint_not_reduced ->
    false
;;

let run_admitted_with
      ~prepare_compaction
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  (* Reject work that is already fenced before spending a provider call. This
     preflight owns no lifecycle state and releases immediately. A turn can
     still enter while planning; the final admission and source CAS close that
     race without stranding [compaction_active]. *)
  match
    Keeper_turn_admission.run_compaction_if_free
      ~base_path:config.base_path
      ~keeper_name:meta.name
      (fun () -> ())
  with
  | `Busy block -> `Busy block
  | `Ran () ->
    let base_dir, preparation = prepare_with ~prepare_compaction ~config ~meta in
    let final_admission () =
      Keeper_turn_admission.run_compaction_if_free
        ~base_path:config.base_path
        ~keeper_name:meta.name
        (fun () ->
          match run_start_lifecycle ~config ~meta with
          | Error failure ->
            (match preparation with
             | Ok prepared ->
               Ok
                 (No_compaction
                    (Keeper_post_turn.no_compaction_of_uncommitted_prepared
                       ~cause:
                         Keeper_event_queue_state.Lifecycle_transition_failed_after_dispatch
                       prepared))
             | Error (Keeper_post_turn.No_compaction no_compaction) ->
               Ok (No_compaction no_compaction)
             | Error _ -> Error failure)
          | Ok () -> finish_preparation ~config ~base_dir ~meta preparation)
    in
    let admitted =
      match preparation with
      | Ok prepared ->
        (try final_admission () with
         | Eio.Cancel.Cancelled _ ->
           Eio.Cancel.protect (fun () ->
             `Ran (Ok (no_compaction_after_prepared_cancellation prepared))))
      | Error _ -> final_admission ()
    in
    (match admitted
     with
     | `Busy block ->
       (match preparation with
        | Ok prepared ->
          `No_compaction
            (Keeper_post_turn.no_compaction_of_uncommitted_prepared prepared)
        | Error (Keeper_post_turn.No_compaction no_compaction)
          when preserve_no_compaction_after_final_admission_busy no_compaction.reason ->
          `No_compaction no_compaction
        | Error _ -> `Busy block)
     | `Ran (Error failure) -> `Compaction_failed failure
     | `Ran (Ok (Compacted success)) ->
       observe_manifest ~keeper_name:meta.name success.manifest;
       `Applied success
     | `Ran (Ok (No_compaction no_compaction)) -> `No_compaction no_compaction)
;;


let run_admitted ?exact_execution_guard =
  run_admitted_with
    ~prepare_compaction:
      (Keeper_context_runtime.prepare_compaction ?exact_execution_guard)
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

module For_testing = struct
  let preserve_no_compaction_after_final_admission_busy =
    preserve_no_compaction_after_final_admission_busy
  ;;
end
