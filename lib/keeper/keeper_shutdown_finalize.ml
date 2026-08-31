open Keeper_shutdown_types

type error =
  | Store_error of Keeper_shutdown_store.error
  | Unsupported_phase
  | Finalization_blocked of Keeper_shutdown_types.t
  | Finalization_draining of Keeper_shutdown_types.t * string
  | Completion_failed of Keeper_shutdown_types.t * string
  | Admission_release_failed of Keeper_shutdown_types.t * string

let error_to_string = function
  | Store_error error -> Keeper_shutdown_store.error_to_string error
  | Unsupported_phase -> "Keeper shutdown operation is not ready for finalization"
  | Finalization_blocked
      ({ phase = Blocked { stage; detail }; _ } as operation) ->
    Printf.sprintf
      "Keeper shutdown finalization blocked in operation %s at %s: %s"
      (Operation_id.to_string operation.operation_id)
      (failure_stage_to_string stage)
      detail
  | Finalization_blocked operation ->
    Printf.sprintf
      "Keeper shutdown finalization blocked in operation %s"
      (Operation_id.to_string operation.operation_id)
  | Finalization_draining (operation, detail) ->
    Printf.sprintf
      "Keeper shutdown finalization is draining operation %s: %s"
      (Operation_id.to_string operation.operation_id)
      detail
  | Completion_failed (operation, detail) ->
    Printf.sprintf
      "Keeper shutdown completion delivery failed in operation %s: %s"
      (Operation_id.to_string operation.operation_id)
      detail
  | Admission_release_failed (operation, detail) ->
    Printf.sprintf
      "Keeper shutdown admission release failed in operation %s: %s"
      (Operation_id.to_string operation.operation_id)
      detail
;;

let remove_pending_confirms_by_target_callback
    : (Workspace.config ->
       target_type:Operator_action_constants.target_type ->
       target_id:string option ->
       (int, string) result)
        Atomic.t
  =
  Atomic.make (fun _config ~target_type:_ ~target_id:_ ->
    Error "pending-confirm cleanup implementation is not registered")
;;

let register_remove_pending_confirms_by_target fn =
  Atomic.set remove_pending_confirms_by_target_callback fn
;;

let completion_handler
    : (Workspace.config ->
       Keeper_shutdown_types.t ->
       Keeper_shutdown_types.completion_action ->
       (unit, string) result)
        Atomic.t
  =
  Atomic.make (fun _config _operation _action ->
    Error "shutdown completion handler is not registered")
;;

let register_completion_handler handler = Atomic.set completion_handler handler

let replace ~config operation =
  let next = { operation with revision = operation.revision + 1 } in
  Keeper_shutdown_store.replace
    ~config
    ~expected_revision:operation.revision
    next
  |> Result.map (fun () -> next)
  |> Result.map_error (fun error -> Store_error error)
;;

let block ~config operation stage detail =
  let blocked =
    { operation with
      phase = Blocked { stage; detail }
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  match replace ~config blocked with
  | Ok persisted -> Error (Finalization_blocked persisted)
  | Error _ as error -> error
;;

let task_id_equal = Keeper_id.Task_id.equal
let task_id_mem task_id task_ids = List.exists (task_id_equal task_id) task_ids

let operation_evidence_ref operation =
  "masc://keeper-shutdown/" ^ Operation_id.to_string operation.operation_id
;;

let task_has_operation_receipt operation (task : Masc_domain.task) =
  match task.task_status, task.handoff_context with
  | Masc_domain.Todo, Some handoff ->
    handoff.reclaim_policy = Some Masc_domain.Allow_reclaim
    && List.exists
         (String.equal (operation_evidence_ref operation))
         handoff.evidence_refs
  | Masc_domain.Claimed _, _
  | Masc_domain.InProgress _, _
  | Masc_domain.AwaitingVerification _, _
  | Masc_domain.Done _, _
  | Masc_domain.Cancelled _, _
  | Masc_domain.Todo, None -> false
;;

let strict_backlog ~config =
  Workspace_backlog.read_backlog_r config
  |> Result.map_error (fun detail -> detail)
;;

let find_task tasks task_id =
  let wire = Keeper_id.Task_id.to_string task_id in
  List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id wire) tasks
;;

let persist_settled ~config operation ~settled_task_ids ~expected_backlog_version =
  let updated =
    { operation with
      expected_backlog_version
    ; phase = Finalizing_tasks settled_task_ids
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  match replace ~config updated with
  | Ok persisted -> Ok persisted
  | Error _ as error -> error
;;

let release_task ~config operation (owned : Keeper_current_task_reconcile.owned_active_task) =
  let assignee =
    match owned.task.task_status with
    | Masc_domain.Claimed { assignee; _ }
    | Masc_domain.InProgress { assignee; _ } -> Ok assignee
    | Masc_domain.Todo
    | Masc_domain.AwaitingVerification _
    | Masc_domain.Done _
    | Masc_domain.Cancelled _ -> Error "snapshotted task is no longer actively owned"
  in
  let handoff_context : Masc_domain.task_handoff_context =
    { summary = "Keeper stopped; task returned to the durable backlog"
    ; reason = Some "Keeper shutdown operation completed lane join"
    ; next_step = Some "A live Keeper may reclaim this task"
    ; failure_mode = None
    ; reclaim_policy = Some Masc_domain.Allow_reclaim
    ; evidence_refs = [ operation_evidence_ref operation ]
    ; updated_at = Some (Masc_domain.now_iso ())
    ; updated_by = Some operation.actor
    }
  in
  match assignee with
  | Error _ as error -> error
  | Ok agent_name ->
    Workspace.release_task_r
      config
      ~agent_name
      ~task_id:(Keeper_id.Task_id.to_string owned.task_id)
      ~expected_version:operation.expected_backlog_version
      ~handoff_context
      ()
    |> Result.map_error Masc_domain.masc_error_to_string
;;

let rec settle_tasks ~config ~meta operation settled_task_ids =
  match
    Keeper_current_task_reconcile.owned_active_tasks_snapshot_for_meta_strict
      ~config
      ~meta
  with
  | Error detail -> block ~config operation Task_settlement detail
  | Ok active_snapshot ->
    let active_tasks = active_snapshot.tasks in
    let unexpected =
      List.filter
        (fun task -> not (task_id_mem task.Keeper_current_task_reconcile.task_id operation.owned_task_ids))
        active_tasks
    in
    if unexpected <> []
    then
      let ids =
        unexpected
        |> List.map (fun task ->
          Keeper_id.Task_id.to_string task.Keeper_current_task_reconcile.task_id)
        |> String.concat ","
      in
      block ~config operation Task_settlement ("new active task ownership: " ^ ids)
    else
      let active_ids =
        List.map
          (fun task -> task.Keeper_current_task_reconcile.task_id)
          active_tasks
      in
      let outstanding_ids =
        List.filter
          (fun task_id -> not (task_id_mem task_id settled_task_ids))
          operation.owned_task_ids
      in
      let receipted_ids =
        List.filter
          (fun task_id ->
             match find_task active_snapshot.backlog_tasks task_id with
             | Some task -> task_has_operation_receipt operation task
             | None -> false)
          outstanding_ids
      in
      let outstanding_accounted_for accounted_task_ids =
        List.for_all
          (fun task_id ->
             task_id_mem task_id accounted_task_ids || task_id_mem task_id active_ids)
          outstanding_ids
      in
      if Int.equal active_snapshot.backlog_version operation.expected_backlog_version
      then
        if receipted_ids <> []
        then
          block
            ~config
            operation
            Task_settlement
            "shutdown receipt exists without a corresponding backlog version change"
        else
          let backlog = active_snapshot.backlog_tasks in
          let rec loop current settled = function
            | [] -> Ok (current, settled)
            | task_id :: rest when task_id_mem task_id settled ->
              loop current settled rest
            | task_id :: rest ->
              let settle_result =
                if task_id_mem task_id active_ids
                then
                  (match
                     List.find_opt
                       (fun task ->
                          task_id_equal
                            task.Keeper_current_task_reconcile.task_id
                            task_id)
                       active_tasks
                   with
                   | None -> Error "active task snapshot disappeared"
                   | Some owned -> release_task ~config current owned)
                else
                  match find_task backlog task_id with
                  | Some task when task_has_operation_receipt current task ->
                    Ok "already released"
                  | Some _ -> Error "snapshotted task changed without shutdown receipt"
                  | None -> Error "snapshotted task disappeared from the durable backlog"
              in
              (match settle_result with
               | Error detail -> block ~config current Task_settlement detail
               | Ok _ ->
                 (match strict_backlog ~config with
                  | Error detail -> block ~config current Task_settlement detail
                  | Ok latest_backlog ->
                    if
                      not
                        (Int.equal
                           latest_backlog.version
                           (current.expected_backlog_version + 1))
                    then
                      settle_tasks ~config ~meta current settled
                    else
                      let settled = task_id :: settled in
                      (match
                         persist_settled
                           ~config
                           current
                           ~settled_task_ids:settled
                           ~expected_backlog_version:latest_backlog.version
                       with
                       | Error _ as error -> error
                       | Ok persisted -> loop persisted settled rest)))
          in
          loop operation settled_task_ids operation.owned_task_ids
      else if outstanding_accounted_for receipted_ids
      then
        (match receipted_ids with
         | [] ->
           (match
              persist_settled
                ~config
                operation
                ~settled_task_ids
                ~expected_backlog_version:active_snapshot.backlog_version
            with
            | Error _ as error -> error
            | Ok rebased -> settle_tasks ~config ~meta rebased settled_task_ids)
         | [ receipted_id ] ->
           let settled_task_ids = receipted_id :: settled_task_ids in
           (match
              persist_settled
                ~config
                operation
                ~settled_task_ids
                ~expected_backlog_version:active_snapshot.backlog_version
            with
            | Error _ as error -> error
            | Ok recovered -> settle_tasks ~config ~meta recovered settled_task_ids)
         | _ ->
           block
             ~config
             operation
             Task_settlement
             "multiple uncommitted shutdown receipts require operator reconciliation")
      else
        block
          ~config
          operation
          Task_settlement
          (Printf.sprintf
             "backlog changed and snapshotted task ownership diverged: expected version %d, actual %d"
             operation.expected_backlog_version
             active_snapshot.backlog_version)
;;

let paused_meta (meta : Keeper_meta_contract.keeper_meta) =
  { meta with
    current_task_id = None
  ; paused = true
  ; latched_reason =
      Some
        (Keeper_latched_reason.Operator_paused
           { operator_actor = Keeper_latched_reason.operator_actor_keeper_down })
  ; updated_at = Masc_domain.now_iso ()
  }
;;

let read_operation_meta ~config operation =
  match
    Keeper_owner_registry.get
      ~base_path:config.Workspace.base_path
      ~keeper_name:operation.keeper_name
  with
  | Error error -> Error (Keeper_owner_registry.lookup_error_to_string error)
  | Ok owner ->
    (match Keeper_owner.exact_projection owner with
     | Error error -> Error (Keeper_owner.error_to_string error)
     | Ok { meta = None; _ } -> Error "Keeper metadata is absent"
     | Ok { meta = Some meta; _ } ->
       if
         Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id
       then Ok meta
       else Error "Keeper metadata identity changed")
;;

let validate_registry_owner_exact ~config operation =
  match
    operation.lane_ownership,
    Keeper_registry.get ~base_path:config.Workspace.base_path operation.keeper_name
  with
  | Dormant_meta, None
  | Registered_lane _, None -> Ok ()
  | Dormant_meta, Some _ ->
    Error "dormant Keeper operation found a registered lane before cleanup"
  | Registered_lane lane_id, Some registry_entry ->
    if
      not
        (Keeper_lane.Id.equal
           (Keeper_lane.id registry_entry.Keeper_registry.lane)
           lane_id)
    then Error "Keeper registry lane changed before cleanup"
    else Ok ()
;;

let prepare_cleanup ~config ~entry operation settled_task_ids =
  let meta_prepare_result =
    match operation.cleanup_intent.reason with
    | Dashboard_keeper_purge _ ->
      (match read_operation_meta ~config operation with
       | Error _ as error -> error
       | Ok meta ->
         validate_registry_owner_exact ~config operation
         |> Result.map (fun () -> meta))
    | Operator_stop_retain_meta
    | Operator_stop_remove_meta ->
      (match
         Keeper_owner_registry.apply_meta
           ~base_path:config.Workspace.base_path
           ~keeper_name:operation.keeper_name
           (Keeper_owner_reducer.Retain_shutdown_latch
              { latch = Keeper_owner_reducer.Operator_stopped
              ; updated_at = Masc_domain.now_iso ()
              })
       with
       | Error error -> Error (Keeper_owner_registry.command_error_to_string error)
       | Ok None -> Error "Keeper metadata disappeared during shutdown pause"
       | Ok (Some retained) -> Ok retained)
    | Supervisor_cleanup ->
      (* The keeper's process is not there. Its metadata is removed like any
         other cleanup; nothing is retained that would refuse a later start. *)
      (match read_operation_meta ~config operation with
       | Error _ as error -> error
       | Ok meta ->
         validate_registry_owner_exact ~config operation
         |> Result.map (fun () -> meta))
  in
  match meta_prepare_result with
  | Error detail -> block ~config operation Meta_update detail
  | Ok prepared_meta ->
    (match validate_registry_owner_exact ~config operation with
     | Error detail -> block ~config operation Meta_update detail
     | Ok () ->
         (match
            Atomic.get remove_pending_confirms_by_target_callback
              config
              ~target_type:Operator_action_constants.Keeper
              ~target_id:(Some operation.keeper_name)
          with
          | Error detail -> block ~config operation Pending_confirm_cleanup detail
          | Ok pending_confirms_removed ->
            let cleanup =
              { settled_task_ids
              ; pending_confirms_removed
              ; meta_snapshot_digest =
                  Keeper_meta_json.Snapshot_digest.of_meta prepared_meta
              }
            in
            let ready =
              { operation with
                phase = Cleanup_ready cleanup
              ; updated_at = Masc_domain.now_iso ()
              }
            in
            (match replace ~config ready with
             | Ok persisted -> Ok persisted
             | Error _ as error -> error)))
;;

let rec remove_tree_blocking path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      let entries = Sys.readdir path |> Array.to_list |> List.sort String.compare in
      let rec remove_entries = function
        | [] ->
          Unix.rmdir path;
          Ok ()
        | entry :: rest ->
          (match remove_tree_blocking (Filename.concat path entry) with
           | Error _ as error -> error
           | Ok () -> remove_entries rest)
      in
      remove_entries entries
    | Unix.S_REG
    | Unix.S_LNK
    | Unix.S_CHR
    | Unix.S_BLK
    | Unix.S_FIFO
    | Unix.S_SOCK ->
      Unix.unlink path;
      Ok ()
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exn -> Error (Printexc.to_string exn)
;;

let remove_tree path =
  try Eio_guard.run_in_systhread (fun () -> remove_tree_blocking path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let remove_meta_file ~config operation cleanup =
  match meta_disposition_of_cleanup_reason operation.cleanup_intent.reason with
  | Retain_operator_pause -> Ok ()
  | Remove_meta ->
    (match
       Keeper_owner_registry.apply_meta
         ~base_path:config.Workspace.base_path
         ~keeper_name:operation.keeper_name
         (Keeper_owner_reducer.Delete_if_snapshot cleanup.meta_snapshot_digest)
     with
     | Ok None -> Ok ()
     | Ok (Some _) -> Error "Keeper owner delete retained metadata"
     | Error
         (Keeper_owner_registry.Command_lookup_failed
            (Keeper_owner_registry.Owner_not_found _)) ->
       (match Keeper_meta_store.read_meta config operation.keeper_name with
        | Ok None -> Ok ()
        | Ok (Some _) -> Error "Keeper metadata exists without its Owner"
        | Error detail -> Error detail)
     | Error error -> Error (Keeper_owner_registry.command_error_to_string error))
;;

let admission_already_released_by_removal ~(config : Workspace.config) operation error =
  match
    meta_disposition_of_cleanup_reason operation.cleanup_intent.reason,
    error
  with
  | ( Remove_meta
    , Keeper_owner_registry.Command_lookup_failed
        (Keeper_owner_registry.Owner_not_found _) ) ->
    (match Keeper_meta_store.read_meta config operation.keeper_name with
     | Ok None ->
       Log.Keeper.info
         "shutdown owner admission already released by Keeper removal: keeper=%s operation=%s"
         operation.keeper_name
         (Operation_id.to_string operation.operation_id);
       true
     | Ok (Some _) | Error _ -> false)
  | Retain_operator_pause, _ | Remove_meta, _ -> false
;;

let remove_session_dir ~config operation =
  if operation.cleanup_intent.remove_session
  then (
    let session_dir =
      Filename.concat
        (Keeper_types_profile.session_base_dir config)
        (Keeper_id.Trace_id.to_string operation.trace_id)
    in
    match
      Keeper_checkpoint_store.with_session_lock ~session_dir (fun session_dir ->
        match remove_tree session_dir with
        | Error _ as error -> error
        | Ok () ->
          Keeper_fs_durable_directory.invalidate session_dir;
          Ok ())
    with
    | Error _ as error -> error
    | Ok result -> result)
  else Ok ()
;;

let validate_exact_registry_generation ~base_path operation entry =
  match operation.lane_ownership, entry with
  | Dormant_meta, None ->
    Keeper_lifecycle_reservation.with_key_lock
      ~base_path
      ~keeper_name:operation.keeper_name
      (fun () ->
         match
           Keeper_registry.get
             ~base_path
             operation.keeper_name
         with
         | Some _ ->
           Error
             "Keeper registry became occupied before dormant finalization fence"
         | None -> Ok ())
  | Dormant_meta, Some _ ->
    Error "dormant Keeper operation found a registered lane before finalization"
  | Registered_lane _, None -> Ok ()
  | Registered_lane expected_lane_id, Some entry ->
    if
      not
        (Keeper_lane.Id.equal
           (Keeper_lane.id entry.Keeper_registry.lane)
           expected_lane_id)
    then Error "Keeper registry lane changed before finalization"
    else Ok ()
;;

let unregister_retired_exact ~base_path operation entry =
  match operation.lane_ownership, entry with
  | Dormant_meta, None -> Ok false
  | Dormant_meta, Some _ ->
    Error "dormant Keeper operation found a registered lane before finalization"
  | Registered_lane _, None -> Ok false
  | Registered_lane expected_lane_id, Some entry ->
    if
      not
        (Keeper_lane.Id.equal
           (Keeper_lane.id entry.Keeper_registry.lane)
           expected_lane_id)
    then Error "Keeper registry lane changed before finalization"
    else
      (match Keeper_registry.unregister_exact entry with
       | Keeper_registry.Exact_unregistered
       | Keeper_registry.Exact_entry_missing -> Ok true
     | Keeper_registry.Exact_entry_replaced ->
       Error "Keeper registry lane was replaced during finalization"
     | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
       Error
         (Printf.sprintf
            "Keeper lifecycle transaction owns registry finalization: %s"
            (Keeper_lifecycle_reservation.snapshot_to_string owner)))
;;

let release_finalized_admission
    ~(config : Workspace.config)
    ?successor_operation_id
    operation
  =
  let release_result =
    match successor_operation_id with
    | None ->
      Keeper_owner_registry.rollback_shutdown
        ~base_path:config.base_path
        ~keeper_name:operation.keeper_name
        ~operation_id:operation.operation_id
      |> Result.map (function
        | Keeper_owner.Shutdown_rolled_back ->
          Keeper_owner.Shutdown_transition_applied
        | Keeper_owner.Shutdown_not_reserved ->
          Keeper_owner.Shutdown_transition_already_applied
        | Keeper_owner.Shutdown_reserved_by_other operation_id ->
          Keeper_owner.Shutdown_transition_reserved_by_other operation_id)
    | Some _ ->
      Keeper_owner_registry.transition_shutdown
        ~base_path:config.base_path
        ~keeper_name:operation.keeper_name
        ~from_operation_id:operation.operation_id
        ~to_operation_id:successor_operation_id
  in
  match release_result with
  | Ok Keeper_owner.Shutdown_transition_applied
  | Ok Keeper_owner.Shutdown_transition_already_applied -> Ok operation
  | Ok (Keeper_owner.Shutdown_transition_reserved_by_other operation_id) ->
    Log.Keeper.warn
      "finalized Keeper shutdown found a newer admission owner: keeper=%s finalized_operation=%s current_operation=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
    (Operation_id.to_string operation_id);
    Ok operation
  | Error error ->
    if admission_already_released_by_removal ~config operation error
    then
      (match
         Keeper_shutdown_intake_fence.transition_shutdown
           ~base_path:config.base_path
           ~keeper_name:operation.keeper_name
           ~from_operation_id:operation.operation_id
           ~to_operation_id:successor_operation_id
       with
       | Keeper_shutdown_intake_fence.Transition_applied
       | Keeper_shutdown_intake_fence.Transition_already_applied -> Ok operation
       | Keeper_shutdown_intake_fence.Transition_reserved_by_other existing ->
         Error
           (Admission_release_failed
              ( operation
              , Printf.sprintf
                  "shutdown intake fence is reserved by another operation: existing=%s"
                  (Operation_id.to_string existing) )))
    else
      Error
        (Admission_release_failed
           (operation, Keeper_owner_registry.command_error_to_string error))
;;

let invoke_completion_handler ~config operation action =
  try Atomic.get completion_handler config operation action with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let deliver_finalized_completion ~config ?successor_operation_id operation =
  match operation.phase with
  | Finalized { completion = Completion_not_requested; _ }
  | Finalized { completion = Completion_delivered _; _ } ->
    release_finalized_admission ~config ?successor_operation_id operation
  | Finalized ({ completion = Completion_pending action; _ } as evidence) ->
    (match invoke_completion_handler ~config operation action with
     | Error detail -> Error (Completion_failed (operation, detail))
     | Ok () ->
       let delivered =
         { operation with
           phase =
             Finalized
               { evidence with completion = Completion_delivered action }
         ; updated_at = Masc_domain.now_iso ()
         }
       in
       (match replace ~config delivered with
        | Error _ as error -> error
        | Ok persisted ->
          release_finalized_admission
            ~config
            ?successor_operation_id
            persisted))
  | Prepared
  | Joining_lanes
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Reconciliation_required _
  | Blocked _
  | Superseded _ -> Error Unsupported_phase
;;

let complete_cleanup
    ~(config : Workspace.config)
    ~entry
    ?successor_operation_id
    operation
    cleanup
  =
  let sandbox_backend =
    match read_operation_meta ~config operation with
    | Error detail -> Error detail
    | Ok meta ->
      Ok
        (match meta.Keeper_meta_contract.sandbox_profile with
         | Keeper_types_profile.Local -> Keeper_sandbox.Local
         | Docker -> Keeper_sandbox.Docker
         | Micro_vm -> Keeper_sandbox.Micro_vm
         | Remote_ssh -> Keeper_sandbox.Remote_ssh)
  in
  let require_released_summary_owner () =
    match operation.cleanup_intent.reason with
    | Operator_stop_retain_meta -> Ok ()
    | Operator_stop_remove_meta
    | Supervisor_cleanup
    | Dashboard_keeper_purge _ ->
      (match
         Keeper_approval_queue.retire_summary_owner
           ~base_path:config.base_path
           ~keeper_name:operation.keeper_name
           ~reason:
             (Printf.sprintf
                "Keeper permanently retired before HITL context summary completed (%s)"
                (cleanup_reason_label operation.cleanup_intent.reason))
       with
       | Ok _ -> Ok ()
       | Error
           (Keeper_approval_queue.Summary_owner_retirement_exact_attempt_unsettled
              _ as error) ->
         Error
           (`Draining
              (Keeper_approval_queue.summary_owner_retirement_error_to_string
                 error))
       | Error error ->
         Error
           (`Failed
              (Printf.sprintf
                 "Keeper cleanup cannot prove approval-summary release: %s"
                 (Keeper_approval_queue.summary_owner_retirement_error_to_string
                    error))))
  in
  let finish registry_unregistered =
    match remove_meta_file ~config operation cleanup with
    | Error detail -> block ~config operation Meta_remove detail
    | Ok () ->
      (match remove_session_dir ~config operation with
       | Error detail -> block ~config operation Session_remove detail
       | Ok () ->
         let meta_removed =
           match meta_disposition_of_cleanup_reason operation.cleanup_intent.reason with
           | Remove_meta -> true
           | Retain_operator_pause -> false
         in
         let accumulator_dropped =
           meta_removed
           || registry_unregistered
           ||
           match operation.lane_ownership with
           | Dormant_meta -> true
           | Registered_lane _ -> false
         in
         if accumulator_dropped
         then Keeper_tool_emission_hook.drop_keeper_accumulator operation.keeper_name;
         let completion =
           match completion_action_of_cleanup_reason operation.cleanup_intent.reason with
           | None -> Completion_not_requested
           | Some action -> Completion_pending action
         in
         let evidence =
           { cleanup
           ; meta_removed
           ; session_removed = operation.cleanup_intent.remove_session
           ; registry_unregistered
           ; accumulator_dropped
           ; completion
           }
         in
         let finalized =
           { operation with
             phase = Finalized evidence
           ; updated_at = Masc_domain.now_iso ()
           }
         in
         match replace ~config finalized with
         | Error _ as error -> error
         | Ok persisted_finalized ->
           deliver_finalized_completion
             ~config
             ?successor_operation_id
             persisted_finalized)
  in
  match validate_exact_registry_generation ~base_path:config.base_path operation entry with
  | Error detail -> block ~config operation Registry_unregister detail
  | Ok () ->
    (match require_released_summary_owner () with
     | Error (`Draining detail) ->
       Error (Finalization_draining (operation, detail))
     | Error (`Failed detail) ->
       block ~config operation Approval_summary_retirement detail
     | Ok () ->
       (match
          unregister_retired_exact ~base_path:config.base_path operation entry
        with
        | Error detail -> block ~config operation Registry_unregister detail
        | Ok registry_unregistered ->
          (* Docker and microVM keep one runtime per keeper across turns, so
             turn teardown deliberately leaves it running; this is the only
             place that knows the keeper is gone for good. Local and remote
             SSH own no local container and must not probe either runtime.

             After the unregister, not before: a failed unregister leaves the
             keeper registered, and a keeper that is still registered must
             keep its sandbox. A teardown failure is logged rather than
             blocking -- the keeper is already gone from the registry, and
             refusing to finish would leave the shutdown half-applied over a
             container that can be removed by hand. *)
          (match
             match sandbox_backend with
             | Error detail -> Error detail
             | Ok backend ->
               Keeper_turn_sandbox_runtime.teardown_keeper_sandbox_by_name
                 ~config
                 ~keeper_name:operation.keeper_name
                 ~backend
                 ()
           with
           | Ok () -> ()
           | Error detail ->
             Log.Keeper.warn
               ~keeper_name:operation.keeper_name
               "keeper removed but its sandbox container was not: %s"
               detail);
          finish registry_unregistered))
;;

let run ~config ~entry ?successor_operation_id operation =
  match operation.phase with
  | Joined_idle ->
    (match read_operation_meta ~config operation with
     | Error detail -> block ~config operation Meta_update detail
     | Ok meta ->
       (match settle_tasks ~config ~meta operation [] with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config ~entry settled_operation settled_task_ids with
           | Error _ as error -> error
           | Ok ready ->
             (match ready.phase with
              | Cleanup_ready cleanup ->
                complete_cleanup
                  ~config
                  ~entry
                  ?successor_operation_id
                  ready
                  cleanup
              | _ -> Error Unsupported_phase))))
  | Finalizing_tasks settled_task_ids ->
    (match read_operation_meta ~config operation with
     | Error detail -> block ~config operation Meta_update detail
     | Ok meta ->
       (match settle_tasks ~config ~meta operation settled_task_ids with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config ~entry settled_operation settled_task_ids with
           | Error _ as error -> error
           | Ok ready ->
             (match ready.phase with
              | Cleanup_ready cleanup ->
                complete_cleanup
                  ~config
                  ~entry
                  ?successor_operation_id
                  ready
                  cleanup
              | _ -> Error Unsupported_phase))))
  | Cleanup_ready cleanup ->
    complete_cleanup
      ~config
      ~entry
      ?successor_operation_id
      operation
      cleanup
  | Finalized _ ->
    deliver_finalized_completion ~config ?successor_operation_id operation
  | Prepared
  | Joining_lanes
  | Reconciliation_required _
  | Blocked _
  | Superseded _ -> Error Unsupported_phase
;;

module For_testing = struct
  let paused_meta = paused_meta

  let remove_pending_confirms_by_target ~config ~target_type ~target_id =
    Atomic.get remove_pending_confirms_by_target_callback config ~target_type ~target_id
  ;;

  let reset_remove_pending_confirms_by_target () =
    Atomic.set remove_pending_confirms_by_target_callback
      (fun _config ~target_type:_ ~target_id:_ ->
      Error "pending-confirm cleanup implementation is not registered")
  ;;

  let reset_completion_handler () =
    Atomic.set completion_handler (fun _config _operation _action ->
      Error "shutdown completion handler is not registered")
  ;;

end
