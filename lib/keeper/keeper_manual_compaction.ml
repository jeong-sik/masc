open Keeper_meta_contract

type post_install_lifecycle =
  | Completion_applied
  | Completion_rejected_failure_dispatched of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error }
  | Completion_rejected_failure_dispatch_failed of
      { completion_error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch_error : Keeper_context_runtime.lifecycle_dispatch_error
      }

type applied_receipt =
  { installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  ; manifest : (unit, string) result
  }

type success =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; receipt : applied_receipt
  }

type committed =
  { recovery : Keeper_context_runtime.compaction_recovery
  ; installation : Keeper_checkpoint_store.installed_checkpoint
  ; lifecycle : post_install_lifecycle
  }

type operation_outcome =
  | Compacted of committed
  | No_compaction of Keeper_post_turn.no_compaction

type pre_install_lifecycle_stage =
  | Operator_request
  | Compaction_started

type failure =
  | Lifecycle_before_install of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      }
  | Lifecycle_before_install_with_failure_dispatch of
      { stage : pre_install_lifecycle_stage
      ; error : Keeper_context_runtime.lifecycle_dispatch_error
      ; failure_dispatch :
          (unit, Keeper_context_runtime.lifecycle_dispatch_error) result
      }
  | Recovery of
      Keeper_post_turn.compaction_recovery_error
      * (unit, Keeper_context_runtime.lifecycle_dispatch_error) result

type admitted_operation =
  [ `Applied of success
  | `No_compaction of Keeper_post_turn.no_compaction
  | `Compaction_failed of failure
  | `Busy of Keeper_turn_admission.autonomous_block
  ]

let checkpoint_ref_to_json (reference : Keeper_checkpoint_ref.t) =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string reference.trace_id)
    ; "generation", `Int reference.generation
    ; "turn_count", `Int reference.turn_count
    ; "sha256", `String reference.sha256
    ]
;;

let exception_auxiliary_json kind (exn, backtrace) =
  `Assoc
    [ "kind", `String kind
    ; "detail", `String (Printexc.to_string exn)
    ; ( "backtrace_present"
      , `Bool (Printexc.raw_backtrace_length backtrace > 0) )
    ; "operator_action_required", `Bool true
    ]
;;

let checkpoint_installation_auxiliary_to_json = function
  | Keeper_checkpoint_store.Commit_durability_unknown error ->
    `Assoc
      [ "kind", `String "commit_durability_unknown"
      ; "detail", `String (Keeper_fs.durable_write_error_to_string error)
      ; "backtrace_present", `Bool false
      ; "operator_action_required", `Bool true
      ]
  | Keeper_checkpoint_store.Commit_observer_failed failure ->
    exception_auxiliary_json "commit_observer_failed" failure
  | Keeper_checkpoint_store.Release_process_lock_failed error ->
    `Assoc
      [ "kind", `String "release_process_lock_failed"
      ; "detail", `String (File_lock_eio.durable_lock_error_to_string error)
      ; "backtrace_present", `Bool false
      ; "operator_action_required", `Bool true
      ]
  | Keeper_checkpoint_store.Post_commit_unwind_interrupted failure ->
    exception_auxiliary_json "post_commit_unwind_interrupted" failure
  | Keeper_checkpoint_store.History_write_failed failure ->
    exception_auxiliary_json "history_write_failed" failure
;;

let post_install_lifecycle_to_json = function
  | Completion_applied ->
    `Assoc
      [ "kind", `String "completion_applied"
      ; "completion_error", `Null
      ; "failure_dispatch", `String "not_needed"
      ; "failure_dispatch_error", `Null
      ; "operator_action_required", `Bool false
      ]
  | Completion_rejected_failure_dispatched { completion_error } ->
    `Assoc
      [ "kind", `String "completion_rejected_failure_dispatched"
      ; ( "completion_error"
        , `String
            (Keeper_context_runtime.lifecycle_dispatch_error_to_string
               completion_error) )
      ; "failure_dispatch", `String "applied"
      ; "failure_dispatch_error", `Null
      ; "operator_action_required", `Bool true
      ]
  | Completion_rejected_failure_dispatch_failed
      { completion_error; failure_dispatch_error } ->
    `Assoc
      [ "kind", `String "completion_rejected_failure_dispatch_failed"
      ; ( "completion_error"
        , `String
            (Keeper_context_runtime.lifecycle_dispatch_error_to_string
               completion_error) )
      ; "failure_dispatch", `String "rejected"
      ; ( "failure_dispatch_error"
        , `String
            (Keeper_context_runtime.lifecycle_dispatch_error_to_string
               failure_dispatch_error) )
      ; "operator_action_required", `Bool true
      ]
;;

let post_install_lifecycle_requires_operator_action = function
  | Completion_applied -> false
  | Completion_rejected_failure_dispatched _
  | Completion_rejected_failure_dispatch_failed _ ->
    true
;;

let queue_auxiliary_of_checkpoint_auxiliary = function
  | Keeper_checkpoint_store.Commit_durability_unknown error ->
    Keeper_event_queue_state.Compaction_commit_durability_unknown
      { detail = Keeper_fs.durable_write_error_to_string error }
  | Keeper_checkpoint_store.Commit_observer_failed (exn, backtrace) ->
    Keeper_event_queue_state.Compaction_commit_observer_failed
      { detail = Printexc.to_string exn
      ; backtrace_present = Printexc.raw_backtrace_length backtrace > 0
      }
  | Keeper_checkpoint_store.Release_process_lock_failed error ->
    Keeper_event_queue_state.Compaction_release_process_lock_failed
      { detail = File_lock_eio.durable_lock_error_to_string error }
  | Keeper_checkpoint_store.Post_commit_unwind_interrupted (exn, backtrace) ->
    Keeper_event_queue_state.Compaction_post_commit_unwind_interrupted
      { detail = Printexc.to_string exn
      ; backtrace_present = Printexc.raw_backtrace_length backtrace > 0
      }
  | Keeper_checkpoint_store.History_write_failed (exn, backtrace) ->
    Keeper_event_queue_state.Compaction_history_write_failed
      { detail = Printexc.to_string exn
      ; backtrace_present = Printexc.raw_backtrace_length backtrace > 0
      }
;;

let queue_lifecycle_of_post_install_lifecycle = function
  | Completion_applied ->
    Keeper_event_queue_state.Compaction_completion_applied
  | Completion_rejected_failure_dispatched { completion_error } ->
    Keeper_event_queue_state.Compaction_completion_rejected_failure_dispatched
      { completion_error =
          Keeper_context_runtime.lifecycle_dispatch_error_to_string
            completion_error
      }
  | Completion_rejected_failure_dispatch_failed
      { completion_error; failure_dispatch_error } ->
    Keeper_event_queue_state.
      Compaction_completion_rejected_failure_dispatch_failed
        { completion_error =
            Keeper_context_runtime.lifecycle_dispatch_error_to_string
              completion_error
        ; failure_dispatch_error =
            Keeper_context_runtime.lifecycle_dispatch_error_to_string
              failure_dispatch_error
        }
;;

let queue_commit_of_applied_receipt (receipt : applied_receipt) =
  { Keeper_event_queue_state.installed_ref = receipt.installation.installed_ref
  ; auxiliary =
      List.map
        queue_auxiliary_of_checkpoint_auxiliary
        receipt.installation.auxiliary
  ; lifecycle = queue_lifecycle_of_post_install_lifecycle receipt.lifecycle
  ; manifest_error =
      (match receipt.manifest with
       | Ok () -> None
       | Error detail -> Some detail)
  }
;;

let append_manifest
    ~config
    ~base_dir
    ~(meta : keeper_meta)
    ~(installation : Keeper_checkpoint_store.installed_checkpoint)
    ~lifecycle
    recovery =
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
  let operator_action_required =
    installation.auxiliary <> []
    || post_install_lifecycle_requires_operator_action lifecycle
  in
  Keeper_runtime_manifest.make_for_context
    context
    ~event:Keeper_runtime_manifest.Context_compacted
    ~status:(if operator_action_required then "degraded" else "compacted")
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
              ; ( "checkpoint_installation_schema"
                , `String "keeper.checkpoint_installation.v1" )
              ; "checkpoint_installation_state", `String "installed"
              ; ( "checkpoint_installed_ref"
                , checkpoint_ref_to_json installation.installed_ref )
              ; ( "checkpoint_installation_auxiliary"
                , `List
                    (List.map
                       checkpoint_installation_auxiliary_to_json
                       installation.auxiliary) )
              ; ( "compaction_post_install_schema"
                , `String "keeper.compaction.post_install.v1" )
              ; "compaction_lifecycle", post_install_lifecycle_to_json lifecycle
              ; "operator_action_required", `Bool operator_action_required
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
    Error (Lifecycle_before_install { stage = Operator_request; error })
  | Ok () ->
    (match dispatch_event ~config ~meta Keeper_state_machine.Compaction_started with
     | Error error ->
       let failure_dispatch = dispatch_failed ~config ~meta "compaction_start_rejected" in
       Error
         (Lifecycle_before_install_with_failure_dispatch
            { stage = Compaction_started
            ; error
            ; failure_dispatch
            })
     | Ok () -> Ok ())
;;

let run_commit ~config ~meta prepared =
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
    (match recovery.checkpoint_installation with
     | Keeper_checkpoint_store.Not_installed not_installed ->
       let error = Keeper_post_turn.Checkpoint_cas_failed not_installed.cause in
       let failure_dispatch =
         dispatch_failed
           ~config
           ~meta
           (Keeper_post_turn.compaction_recovery_error_to_tag error)
       in
       Error (Recovery (error, failure_dispatch))
     | Keeper_checkpoint_store.Installed installed ->
       let lifecycle =
         match
           Keeper_context_runtime.dispatch_compaction_completed
             ~config
             ~keeper_name:meta.name
             ~origin:Keeper_registry.Operator_compact
         with
         | Ok () -> Completion_applied
         | Error completion_error ->
           Log.Keeper.error
             ~keeper_name:meta.name
             "manual compaction completion lifecycle dispatch failed after durable commit; preserving the committed checkpoint and dispatching typed failure cleanup: %s"
             (Keeper_context_runtime.lifecycle_dispatch_error_to_string
                completion_error);
           (match
              dispatch_failed
                ~config
                ~meta
                "compaction_completed_rejected_after_checkpoint"
            with
            | Ok () ->
              Completion_rejected_failure_dispatched { completion_error }
            | Error failure_dispatch_error ->
              Completion_rejected_failure_dispatch_failed
                { completion_error; failure_dispatch_error })
       in
       Keeper_unified_metrics.broadcast_compaction
         ~name:meta.name
         recovery;
       Ok (Compacted { recovery; installation = installed; lifecycle }))
;;

let finish_preparation ~config ~meta = function
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
  | Ok prepared ->
    run_commit ~config ~meta prepared
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
      ~append_compaction_manifest
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
          | Ok () ->
            finish_preparation
              ~config
              ~meta
              preparation)
    in
    let admitted = final_admission () in
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
     | `Ran (Ok (Compacted committed)) ->
       let manifest =
         append_compaction_manifest
           ~config
           ~base_dir
           ~meta
           ~installation:committed.installation
           ~lifecycle:committed.lifecycle
           committed.recovery
       in
       observe_manifest ~keeper_name:meta.name manifest;
       `Applied
         { recovery = committed.recovery
         ; receipt =
             { installation = committed.installation
             ; lifecycle = committed.lifecycle
             ; manifest
             }
         }
     | `Ran (Ok (No_compaction no_compaction)) -> `No_compaction no_compaction)
;;

let run_admitted
    ?exact_execution_guard
    ~config
    ~meta
    () =
  run_admitted_with
    ~append_compaction_manifest:append_manifest
    ~prepare_compaction:(fun ~base_dir ~meta ~trigger ~projection_request ->
      Keeper_context_runtime.prepare_compaction
        ?exact_execution_guard
        ~base_dir
        ~meta
        ~trigger
        ~projection_request
        ())
    ~config
    ~meta
;;

let pre_install_lifecycle_stage_to_string = function
  | Operator_request -> "operator_request"
  | Compaction_started -> "compaction_started"
;;

let failure_dispatch_to_string = function
  | Ok () -> "applied"
  | Error error ->
    "rejected:" ^ Keeper_context_runtime.lifecycle_dispatch_error_to_string error
;;

let failure_to_string = function
  | Lifecycle_before_install { stage; error } ->
    Printf.sprintf
      "stage=%s installation=not_installed error=%s"
      (pre_install_lifecycle_stage_to_string stage)
      (Keeper_context_runtime.lifecycle_dispatch_error_to_string error)
  | Lifecycle_before_install_with_failure_dispatch
      { stage; error; failure_dispatch } ->
    Printf.sprintf
      "stage=%s installation=not_installed error=%s failure_dispatch=%s"
      (pre_install_lifecycle_stage_to_string stage)
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

  let checkpoint_installation_auxiliary_to_json =
    checkpoint_installation_auxiliary_to_json
  ;;
end
