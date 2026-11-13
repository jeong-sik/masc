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
  | Finalization_blocked
      ({ phase =
           ( Prepared
           | Joining_lanes
           | Joined_idle
           | Finalizing_tasks _
           | Cleanup_ready _
           | Reconciliation_required _
           | Finalized _
           | Owner_absent _
           | Operator_absence_acknowledged _
           | Superseded _ )
       ; _
       } as operation) ->
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
    List.exists
      (String.equal (operation_evidence_ref operation))
      handoff.evidence_refs
  | Masc_domain.Claimed _, _
  | Masc_domain.InProgress _, _
  | Masc_domain.AwaitingVerification _, _
  | Masc_domain.Done _, _
  | Masc_domain.Cancelled _, _
  | Masc_domain.Todo, None -> false
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

let shutdown_release_summary =
  "Keeper stopped; task returned to the durable backlog"
;;

let shutdown_release_reason =
  "Keeper shutdown operation completed lane join"
;;

let shutdown_release_next_step = "A live Keeper may reclaim this task"

let non_empty_trimmed (value : string) : string option =
  if String.trim value = "" then None else Some value
;;

let non_empty_trimmed_opt (value : string option) : string option =
  Option.bind value non_empty_trimmed
;;

let append_unique_evidence_ref (refs : string list) (receipt_ref : string)
  : string list
  =
  let non_empty =
    List.filter (fun entry -> String.trim entry <> "") refs
  in
  if List.exists (String.equal receipt_ref) non_empty
  then non_empty
  else non_empty @ [ receipt_ref ]
;;

let release_handoff_context
      ~now
      operation
      (previous : Masc_domain.task_handoff_context option)
  : Masc_domain.task_handoff_context
  =
  let receipt_ref = operation_evidence_ref operation in
  match previous with
  | None ->
    { summary = shutdown_release_summary
    ; reason = Some shutdown_release_reason
    ; next_step = Some shutdown_release_next_step
    ; failure_mode = None
    ; evidence_refs = [ receipt_ref ]
    ; updated_at = Some now
    ; updated_by = Some operation.actor
    }
  | Some prev ->
    let summary =
      match non_empty_trimmed prev.summary with
      | Some preserved -> preserved
      | None -> shutdown_release_summary
    in
    let next_step =
      match non_empty_trimmed_opt prev.next_step with
      | Some _ as preserved -> preserved
      | None -> Some shutdown_release_next_step
    in
    { summary
    ; reason = Some shutdown_release_reason
    ; next_step
    ; failure_mode = non_empty_trimmed_opt prev.failure_mode
    ; evidence_refs = append_unique_evidence_ref prev.evidence_refs receipt_ref
    ; updated_at = Some now
    ; updated_by = Some operation.actor
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

let shutdown_release_plan ~config ~(meta : Keeper_meta_contract.keeper_meta)
    ~updated_at operation settled_task_ids
    (backlog : Masc_domain.backlog) (task : Masc_domain.task) =
  let open Result.Syntax in
  let refused detail = Error (Masc_domain.Task (Masc_domain.Task_error.InvalidState detail)) in
  let owned (task : Masc_domain.task) = match task.task_status with
    | Masc_domain.Claimed { assignee; _ } | InProgress { assignee; _ } ->
        Workspace_task_classify.same_task_actor config assignee meta.name
    | Todo | AwaitingVerification _ | Done _ | Cancelled _ -> false in
  let original id = List.exists (fun recorded ->
    String.equal id (Keeper_id.Task_id.to_string recorded)) operation.owned_task_ids in
  let unexpected = List.filter_map (fun (task : Masc_domain.task) ->
    if owned task && not (original task.id) then Some task.id else None) backlog.tasks in
  let* () = if unexpected = [] then Ok () else
    refused ("new active task ownership: " ^ String.concat "," unexpected) in
  let outstanding = List.filter (fun id -> not (task_id_mem id settled_task_ids))
      operation.owned_task_ids in
  let* receipted = List.fold_left (fun result id ->
    let* receipts = result in
    let wire = Keeper_id.Task_id.to_string id in
    match List.filter (fun (candidate : Masc_domain.task) -> String.equal candidate.id wire) backlog.tasks with
    | [candidate] when owned candidate -> Ok receipts
    | [candidate] when task_has_operation_receipt operation candidate -> Ok (id :: receipts)
    | [_] -> refused "snapshotted task changed without shutdown receipt"
    | [] -> refused "snapshotted task disappeared from the durable backlog"
    | _ :: _ :: _ -> refused "snapshotted task identity is ambiguous in the durable backlog")
      (Ok []) outstanding in
  let* () = if receipted <> [] && Int.equal backlog.version operation.expected_backlog_version then
      refused "shutdown receipt exists without a corresponding backlog version change"
    else match receipted with
      | [] | [_] -> Ok ()
      | _ :: _ :: _ -> refused "multiple uncommitted shutdown receipts require operator reconciliation" in
  match receipted with
  | [id] -> Ok (Workspace.Already_receipted (Keeper_id.Task_id.to_string id))
  | [] ->
    if owned task then Ok (Workspace.Release_with_handoff
      (release_handoff_context ~now:updated_at operation task.handoff_context))
    else refused "snapshotted task changed without shutdown receipt"
  | _ :: _ :: _ -> refused "multiple uncommitted shutdown receipts require operator reconciliation"
;;

let rec settle_tasks_observing ~before_release ~config ~meta operation settled_task_ids =
  match Keeper_current_task_reconcile.owned_active_tasks_snapshot_for_meta_strict ~config ~meta with
  | Error detail -> block ~config operation Task_settlement detail
  | Ok snapshot ->
    let unexpected = List.filter (fun owned ->
      not (task_id_mem owned.Keeper_current_task_reconcile.task_id operation.owned_task_ids))
        snapshot.tasks in
    if unexpected <> [] then
      block ~config operation Task_settlement ("new active task ownership: " ^
        String.concat "," (List.map (fun owned ->
          Keeper_id.Task_id.to_string owned.Keeper_current_task_reconcile.task_id) unexpected))
    else
      match List.filter (fun id -> not (task_id_mem id settled_task_ids)) operation.owned_task_ids with
      | [] ->
        if Int.equal snapshot.backlog_version operation.expected_backlog_version then
          Ok (operation, settled_task_ids)
        else persist_settled ~config operation ~settled_task_ids
            ~expected_backlog_version:snapshot.backlog_version
          |> Result.map (fun persisted -> persisted, settled_task_ids)
      | task_id :: _ ->
        (* The observer exercises the old gap. The transition below then reads,
           validates and releases under one canonical backlog acquisition. *)
        before_release ();
        let released =
          (* Metadata writers use lifecycle key -> owner mailbox. Keep that
             key from the exact owner observation through the Task commit,
             then release it before the shutdown Store CAS. The pure planner
             never calls a mailbox under the canonical backlog lock. Release
             projections update agent records/logs, not the Keeper owner; the
             terminal/verification hooks do not run for Release. *)
          Keeper_lifecycle_reservation.with_key_lock
            ~base_path:config.Workspace.base_path ~keeper_name:operation.keeper_name
            (fun () ->
              match read_operation_meta ~config operation with
              | Error _ as error -> error
              | Ok meta ->
                let updated_at = Masc_domain.now_iso () in
                Workspace.release_task_for_shutdown_r config ~agent_name:meta.name
                  ~task_id:(Keeper_id.Task_id.to_string task_id)
                  ~plan:(shutdown_release_plan ~config ~meta ~updated_at operation settled_task_ids) ()
                |> Result.map (fun receipt -> meta, receipt)
                |> Result.map_error Masc_domain.masc_error_to_string)
        in
        (match released with
         | Error detail -> block ~config operation Task_settlement detail
         | Ok (meta, receipt) ->
             (match receipt.post_commit_error with
              | None -> ()
              | Some error -> Log.Keeper.warn ~keeper_name:operation.keeper_name
                  "shutdown Task release committed with degraded projection: %s"
                  (Masc_domain.masc_error_to_string error));
             let settled_id = List.find_opt (fun id ->
               String.equal (Keeper_id.Task_id.to_string id) receipt.task_id)
               operation.owned_task_ids in
             (match settled_id with
              | None -> block ~config operation Task_settlement
                  "shutdown release returned a Task outside its original scope"
              | Some settled_id when task_id_mem settled_id settled_task_ids ->
                block ~config operation Task_settlement
                  "shutdown release returned an already recorded Task"
              | Some settled_id ->
             let settled_task_ids = match receipt.release with
               | Workspace.Shutdown_released | Workspace.Shutdown_receipted ->
                 settled_id :: settled_task_ids in
             (* This is the revision returned by the actual commit (or checked
                receipt), never an inference from a later unlocked read. *)
             match persist_settled ~config operation ~settled_task_ids
                 ~expected_backlog_version:receipt.backlog_version with
             | Error _ as error -> error
             | Ok persisted ->
               settle_tasks_observing ~before_release ~config ~meta persisted settled_task_ids))
;;

let settle_tasks ~config ~meta operation settled_task_ids =
  settle_tasks_observing ~before_release:(fun () -> ()) ~config ~meta
    operation settled_task_ids
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

let prepare_cleanup ~config operation settled_task_ids =
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
  try Eio_guard.run_in_systhread ~label:"shutdown-remove-tree" (fun () -> remove_tree_blocking path) with
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
     | Error
         (( Keeper_owner_registry.Command_lookup_failed
              ( Keeper_owner_registry.Inventory_not_installed _
              | Keeper_owner_registry.Owner_unavailable _
              | Keeper_owner_registry.Owner_initialization_failed _
              | Keeper_owner_registry.Inventory_stopping )
          | Keeper_owner_registry.Command_lifecycle_reserved _
          | Keeper_owner_registry.Command_rejected _ ) as error) ->
       Error (Keeper_owner_registry.command_error_to_string error))
;;

(* What a failed owner-side admission release means once the owner registry
   answers [Owner_not_found]. Only the keeper's metadata can say more: with
   the metadata gone too, the Keeper was removed outright, and the cleanup
   intent decides what that removal means for this operation. Leftover
   metadata, an unreadable meta store, and every other registry answer keep
   the release failed. *)
type ownerless_release =
  | Released_by_removal
  | Retained_meta_lost
  | Not_released

let classify_ownerless_release ~(config : Workspace.config) operation error =
  match error with
  | Keeper_owner_registry.Command_lookup_failed
      (Keeper_owner_registry.Owner_not_found _) ->
    (match Keeper_meta_store.read_meta config operation.keeper_name with
     | Ok None ->
       (match meta_disposition_of_cleanup_reason operation.cleanup_intent.reason with
        | Remove_meta ->
          Log.Keeper.info
            "shutdown owner admission already released by Keeper removal: keeper=%s operation=%s"
            operation.keeper_name
            (Operation_id.to_string operation.operation_id);
          Released_by_removal
        | Retain_operator_pause -> Retained_meta_lost)
     | Ok (Some _) | Error _ -> Not_released)
  | Keeper_owner_registry.Command_lookup_failed
      ( Keeper_owner_registry.Inventory_not_installed _
      | Keeper_owner_registry.Owner_unavailable _
      | Keeper_owner_registry.Owner_initialization_failed _
      | Keeper_owner_registry.Inventory_stopping )
  | Keeper_owner_registry.Command_lifecycle_reserved _
  | Keeper_owner_registry.Command_rejected _ -> Not_released
;;

let admission_already_released_by_removal ~config operation error =
  match classify_ownerless_release ~config operation error with
  | Released_by_removal -> true
  | Retained_meta_lost | Not_released -> false
;;

(* A finalized retained-metadata stop whose owner and metadata are both gone
   is not a release that can still succeed: the owner registry answers
   [Owner_not_found] on every boot, and no retry changes that. The retain
   contract did not hold either, so the operation is not settled and
   reclaimed like a removal. Record the absence once, on the operation
   itself, and stop walking it; the record stays as the evidence and the
   operator acknowledgement can still follow. Before this, every boot
   re-ran the release and logged the same failure (#33635). *)
let record_owner_absence
    ~(config : Workspace.config)
    ?successor_operation_id
    operation
    evidence
  =
  let observed_at = Masc_domain.now_iso () in
  let observed =
    { operation with
      phase = Owner_absent { finalization = evidence; observed_at }
    ; updated_at = observed_at
    }
  in
  match replace ~config observed with
  | Error _ as error -> error
  | Ok persisted ->
    Log.Keeper.warn
      "shutdown owner and retained metadata are both gone; recorded owner absence and stopped retrying: keeper=%s operation=%s"
      persisted.keeper_name
      (Operation_id.to_string persisted.operation_id);
    (* Only this operation's own intake reservation is released. A later
       owner's reservation is not ours to touch. *)
    (match
       Keeper_shutdown_intake_fence.shutdown_operation_id
         ~base_path:config.base_path
         ~keeper_name:operation.keeper_name
     with
     | Some existing when Operation_id.equal existing operation.operation_id ->
       (match
          Keeper_shutdown_intake_fence.transition_shutdown
            ~base_path:config.base_path
            ~keeper_name:operation.keeper_name
            ~from_operation_id:operation.operation_id
            ~to_operation_id:successor_operation_id
        with
        | Keeper_shutdown_intake_fence.Transition_applied _
        | Keeper_shutdown_intake_fence.Transition_already_applied
        | Keeper_shutdown_intake_fence.Transition_reserved_by_other _ -> ())
     | None | Some _ -> ());
    Ok persisted
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

let unregister_retired_exact operation entry =
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
    ~evidence
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
    (match classify_ownerless_release ~config operation error with
     | Released_by_removal ->
       (match
          Keeper_shutdown_intake_fence.transition_shutdown
            ~base_path:config.base_path
            ~keeper_name:operation.keeper_name
            ~from_operation_id:operation.operation_id
            ~to_operation_id:successor_operation_id
        with
        | Keeper_shutdown_intake_fence.Transition_applied _
        | Keeper_shutdown_intake_fence.Transition_already_applied -> Ok operation
        | Keeper_shutdown_intake_fence.Transition_reserved_by_other existing ->
          Error
            (Admission_release_failed
               ( operation
               , Printf.sprintf
                   "shutdown intake fence is reserved by another operation: existing=%s"
                   (Operation_id.to_string existing) )))
     | Retained_meta_lost ->
       record_owner_absence ~config ?successor_operation_id operation evidence
     | Not_released ->
       Error
         (Admission_release_failed
            (operation, Keeper_owner_registry.command_error_to_string error)))
;;

let invoke_completion_handler ~config operation action =
  try Atomic.get completion_handler config operation action with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let deliver_finalized_completion ~config ?successor_operation_id operation =
  match operation.phase with
  | Finalized
      ({ completion = (Completion_not_requested | Completion_delivered _); _ } as
       evidence) ->
    release_finalized_admission ~config ?successor_operation_id ~evidence operation
  | Finalized ({ completion = (Completion_pending action | Completion_delivery_failed { action; _ }); _ } as evidence) ->
    (match invoke_completion_handler ~config operation action with
     | Error detail ->
       let failed = { operation with
         phase = Finalized { evidence with completion = Completion_delivery_failed { action; detail } };
         updated_at = Masc_domain.now_iso () } in
       (match replace ~config failed with
        | Error _ as error -> error
        | Ok persisted -> Error (Completion_failed (persisted, detail)))
     | Ok () ->
       let delivered_evidence =
         { evidence with completion = Completion_delivered action }
       in
       let delivered =
         { operation with
           phase = Finalized delivered_evidence
         ; updated_at = Masc_domain.now_iso ()
         }
       in
       (match replace ~config delivered with
        | Error _ as error -> error
        | Ok persisted ->
          release_finalized_admission
            ~config
            ?successor_operation_id
            ~evidence:delivered_evidence
            persisted))
  | Prepared
  | Joining_lanes
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Reconciliation_required _
  | Blocked _
  | Owner_absent _
  | Operator_absence_acknowledged _
  | Superseded _ -> Error Unsupported_phase
;;

let remove_volumes_after_teardown ~teardown ~remove =
  match teardown with
  | Ok () -> remove ()
  | Error detail -> Error ("sandbox teardown was not confirmed: " ^ detail)
;;

let complete_cleanup
    ~(config : Workspace.config)
    ~entry
    ?successor_operation_id
    operation
    cleanup
  =
  (* Teardown runs after the registry entry is gone, so the microVM runtime
     has to be read here, while the meta is still readable, and carried to the
     call. Dropping it would send Apple's removal spelling to a guest another
     runtime booted -- or, since the teardown refuses an unnamed runtime,
     remove nothing at all and leave the guest running. *)
  let effective_meta =
    (* The exact owner projection carries durable metadata. Its decoder leaves
       the TOML-owned microvm_backend unset; use the canonical profile resolution
       used at boot before choosing the teardown runtime. *)
    Result.bind
      (read_operation_meta ~config operation)
      (Keeper_meta_contract.effective_meta_result ~base_path:config.base_path)
  in
  let sandbox_backend =
    Result.map
      (fun (meta : Keeper_meta_contract.keeper_meta) ->
         (meta.sandbox_profile, meta.microvm_backend))
      effective_meta
  in
  (* The claims helper that releases the Apple volumes runs on the keeper's
     own sandbox image, resolved the same way the boot resolved it. There is
     no image to fall back to: an unresolvable one leaves the removal
     refused and the warning below names the volumes it kept. *)
  let release_sandbox_image () =
    match effective_meta with
    | Error _ -> None
    | Ok meta ->
      (match
         Keeper_sandbox_image_resolver.for_keeper ~base_path:config.base_path meta
       with
       | Ok pinned -> Some pinned.Keeper_sandbox_image_catalog.reference
       | Error _ -> None)
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
           (Keeper_approval_queue_result.Summary_owner_retirement_exact_attempt_unsettled
              _ as error) ->
         Error
           (`Draining
              (Keeper_approval_queue_result.summary_owner_retirement_error_to_string
                 error))
       | Error
           (Keeper_approval_queue_result.Summary_owner_retirement_storage_error _
            as error) ->
         Error
           (`Failed
              (Printf.sprintf
                 "Keeper cleanup cannot prove approval-summary release: %s"
                 (Keeper_approval_queue_result.summary_owner_retirement_error_to_string
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
          unregister_retired_exact operation entry
        with
        | Error detail -> block ~config operation Registry_unregister detail
        | Ok registry_unregistered ->
          (* Docker and microVM keep one runtime per keeper across turns, so
             turn teardown deliberately leaves it running; this is the only
             place that knows the keeper is gone for good. Remote SSH owns
             no local container and must not probe either runtime.

             After the unregister, not before: a failed unregister leaves the
             keeper registered, and a keeper that is still registered must
             keep its sandbox. A teardown failure is logged rather than
             blocking -- the keeper is already gone from the registry, and
             refusing to finish would leave the shutdown half-applied over a
             container that can be removed by hand. *)
          let teardown =
             match sandbox_backend with
             | Error detail -> Error detail
             | Ok (backend, microvm_backend) ->
               Keeper_turn_sandbox_runtime.teardown_keeper_sandbox_by_name
                 ~config
                 ~keeper_name:operation.keeper_name
                 ~backend
                 ?microvm_backend
                 () in
          (match teardown with
           | Ok () -> ()
           | Error detail ->
             Log.Keeper.warn
               ~keeper_name:operation.keeper_name
               "keeper removed but sandbox cleanup was not fully confirmed: %s"
               detail);
          (* A Keeper whose meta stays is let go by the next move, which reads
             it as stopped. One removed for good leaves only its credential,
             which reads like an agent coming back, so the controller it holds
             is freed here. Logged rather than blocking, like the teardown
             above. *)
          (match meta_disposition_of_cleanup_reason operation.cleanup_intent.reason with
           | Retain_operator_pause -> ()
           | Remove_meta ->
             (* The teardown above leaves the volumes, since a paused keeper
                comes back to its work volume. This one is not coming back.
                Logged rather than blocking, like the teardown: a skipped or
                unconfirmed cleanup is reported for ownership reconciliation. *)
             (match remove_volumes_after_teardown ~teardown ~remove:(fun () ->
                match sandbox_backend with
                | Error detail -> Error detail
                | Ok (backend, microvm_backend) ->
                  Keeper_turn_sandbox_runtime.remove_keeper_volumes_by_name
                    ~base_path:config.base_path
                    ~keeper_name:operation.keeper_name
                    ~backend
                    ?microvm_backend
                    ?sandbox_image:(release_sandbox_image ())
                    ())
              with
              | Ok () -> ()
              | Error detail ->
                Log.Keeper.warn
                  ~keeper_name:operation.keeper_name
                  "keeper removed; volume cleanup was skipped or unconfirmed: %s"
                  detail);
             (* The worktrees its clones registered stay on disk the same
                way. A dirty one is removed with it; a locked one is refused by git
                and named in a warning. *)
             (match effective_meta with
              | Error detail ->
                Log.Keeper.warn
                  ~keeper_name:operation.keeper_name
                  "keeper removed but its worktrees were not looked for: %s"
                  detail
              | Ok meta ->
                Keeper_bundle_worktrees.remove_keeper_worktrees
                  ~run_argv:(fun ~timeout_sec argv ->
                    Process_eio.run_argv_with_status ~timeout_sec argv)
                  ~timeout_sec:
                    (Env_config_sandbox.Shell_timeout.timeout_sec
                       ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
                       ())
                  ~base_path:config.base_path
                  ~keeper_name:operation.keeper_name
                  ~profile:meta.sandbox_profile
                |> Keeper_bundle_worktrees.log_outcomes ~keeper_name:operation.keeper_name);
             (match
                Keeper_dos_controller.release_retired ~config
                  ~keeper_name:operation.keeper_name
                  ~by:operation.actor
              with
              | Ok () -> ()
              | Error detail ->
                Log.Keeper.warn
                  ~keeper_name:operation.keeper_name
                  "keeper removed but the DOS controller it held was not released: %s"
                  detail));
          finish registry_unregistered))
;;

let run ~config ~entry ?successor_operation_id operation =
  match operation.phase with
  | Joined_idle ->
    (match read_operation_meta ~config operation with
     | Error detail -> block ~config operation Meta_read detail
     | Ok meta ->
       (match settle_tasks ~config ~meta operation [] with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config settled_operation settled_task_ids with
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
              | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _
              | Reconciliation_required _ | Finalized _ | Owner_absent _
              | Operator_absence_acknowledged _ | Blocked _ | Superseded _ -> Error Unsupported_phase))))
  | Finalizing_tasks settled_task_ids ->
    (match read_operation_meta ~config operation with
     | Error detail -> block ~config operation Meta_read detail
     | Ok meta ->
       (match settle_tasks ~config ~meta operation settled_task_ids with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config settled_operation settled_task_ids with
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
              | Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _
              | Reconciliation_required _ | Finalized _ | Owner_absent _
              | Operator_absence_acknowledged _ | Blocked _ | Superseded _ -> Error Unsupported_phase))))
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
  | Owner_absent _
  | Operator_absence_acknowledged _
  | Superseded _ -> Error Unsupported_phase
;;

type replay_plan =
  | Replay_resume of Keeper_id.Task_id.t list
  | Replay_abandon of boot_replay_abandonment
  | Replay_unavailable of string

(* Read-only: the plan names where [run] resumes and never writes. The trace
   and task checks are the same ones [run] applies (read_operation_meta and
   settle_tasks' unexpected-ownership check), taken before the operation
   leaves [Blocked] so a Keeper that ran after the block is closed as
   overtaken instead of settled against a snapshot it no longer matches. *)
let plan_blocked_replay ~config operation replay =
  match
    Keeper_owner_registry.get
      ~base_path:config.Workspace.base_path
      ~keeper_name:operation.keeper_name
  with
  | Error error -> Replay_unavailable (Keeper_owner_registry.lookup_error_to_string error)
  | Ok owner ->
    (match Keeper_owner.exact_projection owner with
     | Error error -> Replay_unavailable (Keeper_owner.error_to_string error)
     | Ok { meta = None; _ } -> Replay_unavailable "Keeper metadata is absent"
     | Ok { meta = Some meta; _ } ->
       if not (Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id)
       then Replay_abandon Keeper_trace_changed
       else (
         match
           Keeper_current_task_reconcile.owned_active_tasks_snapshot_for_meta_strict
             ~config
             ~meta
         with
         | Error detail -> Replay_unavailable detail
         | Ok snapshot ->
           let new_task_ids =
             List.filter_map
               (fun (owned : Keeper_current_task_reconcile.owned_active_task) ->
                  if task_id_mem owned.task_id operation.owned_task_ids
                  then None
                  else Some owned.task_id)
               snapshot.tasks
           in
           (match new_task_ids with
            | _ :: _ -> Replay_abandon (Keeper_claimed_new_tasks new_task_ids)
            | [] ->
              let receipted_task_ids =
                List.filter
                  (fun task_id ->
                     match find_task snapshot.backlog_tasks task_id with
                     | Some task -> task_has_operation_receipt operation task
                     | None -> false)
                  operation.owned_task_ids
              in
              let still_owned =
                List.exists
                  (fun (owned : Keeper_current_task_reconcile.owned_active_task) ->
                     task_id_mem owned.task_id operation.owned_task_ids)
                  snapshot.tasks
              in
              (* A settled-stage record whose Keeper still owns one of the
                 snapshotted tasks did not come from a completed settlement;
                 treating it as settled would leave that task claimed by a
                 stopped Keeper. Settle from the receipts instead. *)
              (match replay, still_owned with
               | Replay_settled_tasks, false -> Replay_resume operation.owned_task_ids
               | Replay_settled_tasks, true
               | Replay_unsettled_tasks, (true | false) -> Replay_resume receipted_task_ids))))
;;

module For_testing = struct
  let settle_tasks ~before_release ~config operation =
    match read_operation_meta ~config operation with
    | Error detail -> block ~config operation Meta_read detail
    | Ok meta ->
      settle_tasks_observing ~before_release ~config ~meta operation []
  ;;

  let paused_meta = paused_meta
  let remove_volumes_after_teardown = remove_volumes_after_teardown

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
