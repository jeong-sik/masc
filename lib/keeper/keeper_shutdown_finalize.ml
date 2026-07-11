open Keeper_shutdown_types

type error =
  | Store_error of Keeper_shutdown_store.error
  | Unsupported_phase
  | Finalization_blocked of Keeper_shutdown_types.t

let error_to_string = function
  | Store_error error -> Keeper_shutdown_store.error_to_string error
  | Unsupported_phase -> "Keeper shutdown operation is not ready for finalization"
  | Finalization_blocked operation ->
    Printf.sprintf
      "Keeper shutdown finalization blocked in operation %s"
      (Operation_id.to_string operation.operation_id)
;;

let remove_pending_confirms_by_target_callback
    : (Workspace.config ->
       target_type:string ->
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

let replace ~config operation =
  Keeper_shutdown_store.replace ~config operation
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
  | Ok () -> Error (Finalization_blocked blocked)
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

let find_task backlog task_id =
  let wire = Keeper_id.Task_id.to_string task_id in
  List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id wire) backlog.Masc_domain.tasks
;;

let persist_settled ~config operation settled_task_ids =
  let updated =
    { operation with
      phase = Finalizing_tasks settled_task_ids
    ; updated_at = Masc_domain.now_iso ()
    }
  in
  match replace ~config updated with
  | Ok () -> Ok updated
  | Error _ as error -> error
;;

let release_task ~config ~meta operation task_id =
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
  Workspace.force_release_task_r
    config
    ~agent_name:meta.Keeper_meta_contract.agent_name
    ~task_id:(Keeper_id.Task_id.to_string task_id)
    ~handoff_context
    ()
  |> Result.map_error Masc_domain.masc_error_to_string
;;

let settle_tasks ~config ~meta operation settled_task_ids =
  match
    Keeper_current_task_reconcile.owned_active_tasks_for_meta_strict ~config ~meta
  with
  | Error detail -> block ~config operation Task_settlement detail
  | Ok active_tasks ->
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
      match strict_backlog ~config with
      | Error detail -> block ~config operation Task_settlement detail
      | Ok backlog ->
        let active_ids =
          List.map
            (fun task -> task.Keeper_current_task_reconcile.task_id)
            active_tasks
        in
        let rec loop current settled = function
          | [] -> Ok (current, settled)
          | task_id :: rest when task_id_mem task_id settled -> loop current settled rest
          | task_id :: rest ->
            let settle_result =
              if task_id_mem task_id active_ids
              then release_task ~config ~meta current task_id
              else
                match find_task backlog task_id with
                | Some task when task_has_operation_receipt current task -> Ok "already released"
                | Some _ -> Error "snapshotted task changed without shutdown receipt"
                | None -> Error "snapshotted task disappeared from the durable backlog"
            in
            (match settle_result with
             | Error detail -> block ~config current Task_settlement detail
             | Ok _ ->
               let settled = task_id :: settled in
               (match persist_settled ~config current settled with
                | Error _ as error -> error
                | Ok persisted -> loop persisted settled rest))
        in
        loop operation settled_task_ids operation.owned_task_ids
;;

let paused_meta meta =
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

let prepare_cleanup ~config operation settled_task_ids =
  match Keeper_meta_store.read_meta_resolved config operation.keeper_name with
  | Error detail -> block ~config operation Meta_update detail
  | Ok None -> block ~config operation Meta_update "Keeper metadata disappeared before cleanup"
  | Ok (Some (resolved_name, meta)) ->
    if
      (not (String.equal resolved_name operation.keeper_name))
      || not (Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id)
      || not (Int.equal meta.runtime.generation operation.generation)
    then block ~config operation Meta_update "Keeper metadata identity changed"
    else
      let retained = paused_meta meta in
      (match
         Keeper_meta_store.write_meta_with_merge
           ~merge:Keeper_meta_merge.caller_wins
           config
           retained
       with
       | Error detail -> block ~config operation Meta_update detail
       | Ok () ->
         Keeper_registry.update_meta ~base_path:config.base_path operation.keeper_name retained;
         (match
            Atomic.get remove_pending_confirms_by_target_callback
              config
              ~target_type:"keeper"
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
             | Ok () -> Ok ready
             | Error _ as error -> error)))
;;

let rec remove_tree path =
  if not (Fs_compat.file_exists path)
  then Ok ()
  else
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
        let entries = Sys.readdir path |> Array.to_list in
        let rec remove_entries = function
          | [] ->
            Unix.rmdir path;
            Ok ()
          | entry :: rest ->
            (match remove_tree (Filename.concat path entry) with
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
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
;;

let remove_meta_file ~config operation =
  if operation.cleanup_intent.remove_meta
  then remove_tree (Keeper_types_profile.keeper_meta_path config operation.keeper_name)
  else Ok ()
;;

let remove_session_dir ~config operation =
  if operation.cleanup_intent.remove_session
  then
    remove_tree
      (Filename.concat
         (Keeper_types_profile.session_base_dir config)
         (Keeper_id.Trace_id.to_string operation.trace_id))
  else Ok ()
;;

let unregister_exact operation = function
  | None -> Ok false
  | Some entry
    when not (Keeper_lane.Id.equal (Keeper_lane.id entry.Keeper_registry.lane) operation.lane_id) ->
    Error "Keeper registry lane changed before finalization"
  | Some entry ->
    (match Keeper_registry.unregister_exact entry with
     | Keeper_registry.Exact_unregistered
     | Keeper_registry.Exact_entry_missing -> Ok true
     | Keeper_registry.Exact_entry_replaced ->
       Error "Keeper registry lane was replaced during finalization")
;;

let complete_cleanup ~config ~entry operation cleanup =
  match remove_session_dir ~config operation with
  | Error detail -> block ~config operation Session_remove detail
  | Ok () ->
    (match remove_meta_file ~config operation with
     | Error detail -> block ~config operation Meta_remove detail
     | Ok () ->
       (match unregister_exact operation entry with
        | Error detail -> block ~config operation Registry_unregister detail
        | Ok registry_unregistered ->
          if operation.cleanup_intent.remove_meta
          then Keeper_tool_emission_hook.drop_keeper_accumulator operation.keeper_name;
          let evidence =
            { cleanup
            ; meta_removed = operation.cleanup_intent.remove_meta
            ; session_removed = operation.cleanup_intent.remove_session
            ; registry_unregistered
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
           | Ok () ->
             (match
                Keeper_turn_admission.rollback_shutdown
                  ~base_path:config.base_path
                  ~keeper_name:operation.keeper_name
                  ~operation_id:operation.operation_id
              with
              | Keeper_turn_admission.Shutdown_rolled_back
              | Keeper_turn_admission.Shutdown_not_reserved -> Ok finalized
              | Keeper_turn_admission.Shutdown_reserved_by_other _ ->
                block
                  ~config
                  finalized
                  Registry_unregister
                  "admission fence is owned by another shutdown operation"))))
;;

let run ~config ~entry operation =
  match operation.phase with
  | Joined_idle ->
    (match Keeper_meta_store.read_meta_resolved config operation.keeper_name with
     | Error detail -> block ~config operation Meta_update detail
     | Ok None -> block ~config operation Meta_update "Keeper metadata is absent"
     | Ok (Some (_, meta)) ->
       (match settle_tasks ~config ~meta operation [] with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config settled_operation settled_task_ids with
           | Error _ as error -> error
           | Ok ready ->
             (match ready.phase with
              | Cleanup_ready cleanup -> complete_cleanup ~config ~entry ready cleanup
              | _ -> Error Unsupported_phase))))
  | Finalizing_tasks settled_task_ids ->
    (match Keeper_meta_store.read_meta_resolved config operation.keeper_name with
     | Error detail -> block ~config operation Meta_update detail
     | Ok None -> block ~config operation Meta_update "Keeper metadata is absent"
     | Ok (Some (_, meta)) ->
       (match settle_tasks ~config ~meta operation settled_task_ids with
        | Error _ as error -> error
        | Ok (settled_operation, settled_task_ids) ->
          (match prepare_cleanup ~config settled_operation settled_task_ids with
           | Error _ as error -> error
           | Ok ready ->
             (match ready.phase with
              | Cleanup_ready cleanup -> complete_cleanup ~config ~entry ready cleanup
              | _ -> Error Unsupported_phase))))
  | Cleanup_ready cleanup -> complete_cleanup ~config ~entry operation cleanup
  | Finalized _ -> Ok operation
  | Prepared
  | Reconciliation_required _
  | Blocked _ -> Error Unsupported_phase
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
end
