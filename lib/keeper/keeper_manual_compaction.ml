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
  ; commit_count : int
  }

type success =
  { recovery : Keeper_post_turn.compaction_recovery
  ; receipt : applied_receipt
  }

type committed =
  { recovery : Keeper_post_turn.compaction_recovery
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
  ]

let checkpoint_ref_to_json (reference : Keeper_checkpoint_ref.t) =
  `Assoc
    [ "trace_id", `String (Keeper_id.Trace_id.to_string reference.trace_id)
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

let append_manifest
    ~config
    ~base_dir
    ~(meta : keeper_meta)
    ~(installation : Keeper_checkpoint_store.installed_checkpoint)
    ~lifecycle
    recovery =
  let trigger = recovery.Keeper_post_turn.trigger in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let context : Keeper_runtime_manifest.turn_context =
    { manifest_keeper_name = meta.name
    ; manifest_agent_name = Some meta.name
    ; manifest_trace_id = trace_id
    ; manifest_keeper_turn_id = Some recovery.checkpoint.turn_count
    }
  in
  let checkpoint_path =
    Keeper_checkpoint_store.agent_core_checkpoint_path
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
         (Keeper_runtime_manifest.with_compaction_outcome
            ~compaction_outcome:Keeper_runtime_manifest.Checkpoint_committed
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
                 ]))))
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
      "manual compaction terminal lifecycle dispatch failed without redispatching the provider request: %s"
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
  let terminal no_compaction =
    let error = Keeper_post_turn.No_compaction no_compaction in
    let failure_dispatch =
      dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
    in
    observe_terminal_dispatch_failure ~meta failure_dispatch;
    Ok (No_compaction no_compaction)
  in
  let failed error =
    let failure_dispatch =
      dispatch_failed ~config ~meta (Keeper_post_turn.compaction_recovery_error_to_tag error)
    in
    Error (Recovery (error, failure_dispatch))
  in
  let committed (recovery : Keeper_post_turn.compaction_recovery) =
    let installation = recovery.checkpoint_installation in
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
    Ok (Compacted { recovery; installation; lifecycle })
  in
  match Keeper_post_turn.commit_prepared_compaction prepared with
  | Keeper_post_turn.Committed recovery -> committed recovery
  | Keeper_post_turn.Not_committed no_compaction -> terminal no_compaction
  | Keeper_post_turn.Commit_failed { error; committed = None } ->
    failed error
  | Keeper_post_turn.Commit_failed { error; committed = Some recovery } ->
    Log.Keeper.error
      ~keeper_name:meta.name
      "manual compaction committed checkpoint but post-install callback failed: %s"
      (Keeper_post_turn.compaction_recovery_error_to_string error);
    committed recovery
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
  ( base_dir
  , prepare_compaction
      ~base_path:config.base_path
      ~base_dir
      ~meta
      ~trigger:Compaction_trigger.Manual )
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

let run_under_admission_with
      ~append_compaction_manifest
      ~prepare_compaction
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
  =
  let base_dir, preparation = prepare_with ~prepare_compaction ~config ~meta in
  let admitted =
    match run_start_lifecycle ~config ~meta with
    | Error failure -> Error failure
    | Ok () -> finish_preparation ~config ~meta preparation
  in
  match admitted with
  | Error failure ->
    (match preparation with
     | Ok prepared ->
       `No_compaction
         (Keeper_post_turn.no_compaction_of_prepared
            ~cause:Keeper_compaction_outcome.Lifecycle_transition_failed_after_dispatch
            prepared)
     | Error (Keeper_post_turn.No_compaction no_compaction) ->
       `No_compaction no_compaction
     | Error _ -> `Compaction_failed failure)
  | Ok (Compacted committed) ->
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
          ; commit_count = committed.recovery.commit_count
          }
      }
  | Ok (No_compaction no_compaction) -> `No_compaction no_compaction
;;

let run_under_admission
    ?before_dispatch_authority
    ~config
    ~meta
    () =
  run_under_admission_with
    ~append_compaction_manifest:append_manifest
    ~prepare_compaction:(fun ~base_path ~base_dir ~meta ~trigger ->
      Keeper_post_turn.prepare_compaction
        ?before_dispatch_authority
        ~base_path
        ~base_dir
        ~meta
        ~trigger
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
  let checkpoint_installation_auxiliary_to_json =
    checkpoint_installation_auxiliary_to_json
  ;;
end
