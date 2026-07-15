open Keeper_shutdown_types

type error =
  | Store_error of Keeper_shutdown_store.error
  | Unsupported_phase
  | Finalization_blocked of Keeper_shutdown_types.t
  | Completion_failed of Keeper_shutdown_types.t * string

let error_to_string = function
  | Store_error error -> Keeper_shutdown_store.error_to_string error
  | Unsupported_phase -> "Keeper shutdown operation is not ready for finalization"
  | Finalization_blocked operation ->
    Printf.sprintf
      "Keeper shutdown finalization blocked in operation %s"
      (Operation_id.to_string operation.operation_id)
  | Completion_failed (operation, detail) ->
    Printf.sprintf
      "Keeper shutdown completion delivery failed in operation %s: %s"
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
      let outstanding_accounted_for receipt_ids =
        List.for_all
          (fun task_id ->
             task_id_mem task_id receipt_ids || task_id_mem task_id active_ids)
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

let dead_tombstone_meta (meta : Keeper_meta_contract.keeper_meta) =
  { meta with
    current_task_id = None
  ; paused = true
  ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
  ; updated_at = Masc_domain.now_iso ()
  ; runtime = { meta.runtime with last_blocker = None }
  }
;;

let read_operation_meta ~config operation =
  match operation.cleanup_intent.reason with
  | Dashboard_keeper_purge context ->
    (match
       Keeper_meta_store.read_meta_if_exact_identity
         config
         ~name:operation.keeper_name
         ~trace_id:operation.trace_id
         ~generation:operation.generation
         ~meta_version:context.meta_version
     with
     | Ok meta -> Ok meta
     | Error error ->
       Error (Keeper_meta_store.exact_identity_error_to_string error))
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup ->
    (match Keeper_meta_store.read_meta_resolved config operation.keeper_name with
     | Error detail -> Error detail
     | Ok None -> Error "Keeper metadata is absent"
     | Ok (Some (_, meta)) ->
       if
         Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id
         && Int.equal meta.runtime.generation operation.generation
       then Ok meta
       else Error "Keeper metadata identity changed before finalization")
;;

let update_registry_meta_exact operation entry retained =
  match operation.lane_ownership, entry with
  | Dormant_meta, None
  | Registered_lane _, None -> Ok ()
  | Dormant_meta, Some _ ->
    Error "dormant Keeper operation found a registered lane before meta update"
  | Registered_lane lane_id, Some registry_entry
    when not
           (Keeper_lane.Id.equal
              (Keeper_lane.id registry_entry.Keeper_registry.lane)
              lane_id) -> Error "Keeper registry lane changed before meta update"
  | Registered_lane _, Some registry_entry ->
    (match
       Keeper_registry.update_entry_exact registry_entry (fun current ->
         { current with meta = retained })
     with
     | Keeper_registry.Exact_updated -> Ok ()
     | Keeper_registry.Exact_update_missing ->
       Error "Keeper registry entry disappeared before meta update"
     | Keeper_registry.Exact_update_replaced ->
       Error "Keeper registry lane changed during meta update"
     | Keeper_registry.Exact_update_invalid validation_error ->
       Error
         (Keeper_registry.registry_entry_validation_error_to_string validation_error))
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
       | Ok _ -> validate_registry_owner_exact ~config operation)
    | Operator_stop_retain_meta
    | Operator_stop_remove_meta ->
      (match
         Keeper_meta_store.update_meta_if_identity
           config
           ~name:operation.keeper_name
           ~trace_id:operation.trace_id
           ~generation:operation.generation
           paused_meta
       with
       | Error error ->
         Error (Keeper_meta_store.identity_update_error_to_string error)
       | Ok retained -> update_registry_meta_exact operation entry retained)
    | Dead_tombstone_cleanup ->
      (match
         Keeper_meta_store.update_meta_if_identity
           config
           ~name:operation.keeper_name
           ~trace_id:operation.trace_id
           ~generation:operation.generation
           dead_tombstone_meta
       with
       | Error error ->
         Error (Keeper_meta_store.identity_update_error_to_string error)
       | Ok retained -> update_registry_meta_exact operation entry retained)
  in
  match meta_prepare_result with
  | Error detail -> block ~config operation Meta_update detail
  | Ok () ->
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
            let cleanup = { settled_task_ids; pending_confirms_removed } in
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

let remove_meta_file ~config operation =
  match operation.cleanup_intent.reason with
  | Dashboard_keeper_purge context ->
    (match
       Keeper_meta_store.remove_meta_if_exact_identity
         config
         ~name:operation.keeper_name
         ~trace_id:operation.trace_id
         ~generation:operation.generation
         ~meta_version:context.meta_version
     with
     | Ok () -> Ok ()
     | Error Keeper_meta_store.Exact_identity_missing ->
       Log.Keeper.warn
         "%s: exact dashboard-purge metadata already absent during cleanup replay"
         operation.keeper_name;
       Ok ()
     | Error error ->
       Error (Keeper_meta_store.exact_identity_error_to_string error))
  | Operator_stop_remove_meta ->
    (match
       Keeper_meta_store.remove_meta_if_identity
         config
         ~name:operation.keeper_name
         ~trace_id:operation.trace_id
         ~generation:operation.generation
     with
     | Ok () -> Ok ()
     | Error Keeper_meta_store.Remove_identity_missing ->
       Log.Keeper.warn
         "%s: shutdown metadata already absent during cleanup replay"
         operation.keeper_name;
       Ok ()
     | Error error ->
       Error (Keeper_meta_store.identity_remove_error_to_string error))
  | Operator_stop_retain_meta
  | Dead_tombstone_cleanup -> Ok ()
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

let unregister_exact operation entry =
  match operation.lane_ownership, entry with
  | (Dormant_meta | Registered_lane _), None -> Ok false
  | Dormant_meta, Some _ ->
    Error "dormant Keeper operation found a registered lane before finalization"
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

let release_finalized_admission ~(config : Workspace.config) operation =
  match
    Keeper_turn_admission.rollback_shutdown
      ~base_path:config.base_path
      ~keeper_name:operation.keeper_name
      ~operation_id:operation.operation_id
  with
  | Keeper_turn_admission.Shutdown_rolled_back
  | Keeper_turn_admission.Shutdown_not_reserved -> Ok operation
  | Keeper_turn_admission.Shutdown_reserved_by_other operation_id ->
    Log.Keeper.warn
      "finalized Keeper shutdown found a newer admission owner: keeper=%s finalized_operation=%s current_operation=%s"
      operation.keeper_name
      (Operation_id.to_string operation.operation_id)
      (Operation_id.to_string operation_id);
    Ok operation
;;

let invoke_completion_handler ~config operation action =
  try Atomic.get completion_handler config operation action with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let deliver_finalized_completion ~config operation =
  match operation.phase with
  | Finalized { completion = Completion_not_requested; _ }
  | Finalized { completion = Completion_delivered _; _ } ->
    release_finalized_admission ~config operation
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
        | Ok persisted -> release_finalized_admission ~config persisted))
  | Prepared
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Reconciliation_required _
  | Blocked _ -> Error Unsupported_phase
;;

let complete_cleanup ~config ~entry operation cleanup =
  match remove_meta_file ~config operation with
  | Error detail -> block ~config operation Meta_remove detail
  | Ok () ->
    (match unregister_exact operation entry with
     | Error detail -> block ~config operation Registry_unregister detail
     | Ok registry_unregistered ->
       (match remove_session_dir ~config operation with
        | Error detail -> block ~config operation Session_remove detail
        | Ok () ->
          let meta_removed =
            match
              meta_disposition_of_cleanup_reason operation.cleanup_intent.reason
            with
            | Remove_meta -> true
            | Retain_operator_pause
            | Retain_dead_tombstone -> false
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
          (match replace ~config finalized with
           | Error _ as error -> error
           | Ok persisted_finalized ->
             deliver_finalized_completion ~config persisted_finalized)))
;;

let run ~config ~entry operation =
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
              | Cleanup_ready cleanup -> complete_cleanup ~config ~entry ready cleanup
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
              | Cleanup_ready cleanup -> complete_cleanup ~config ~entry ready cleanup
              | _ -> Error Unsupported_phase))))
  | Cleanup_ready cleanup -> complete_cleanup ~config ~entry operation cleanup
  | Finalized _ -> deliver_finalized_completion ~config operation
  | Prepared
  | Reconciliation_required _
  | Blocked _ -> Error Unsupported_phase
;;

module For_testing = struct
  let paused_meta = paused_meta
  let dead_tombstone_meta = dead_tombstone_meta

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
