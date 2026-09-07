open Keeper_shutdown_types

let ( let* ) = Result.bind

type error =
  | Invalid_request of string
  | Store_error of Keeper_shutdown_store.error
  | Ineligible_operation
  | Outstanding_recorded_tasks of string list
  | Outstanding_tasks of string list
  | Outstanding_chat_operations of Keeper_chat_operation.Operation_id.t list
  | Outstanding_semantic_executions of Keeper_execution_scope_id.t list
  | Chat_operations_unavailable of Keeper_chat_operation_store.error
  | Backlog_unavailable of string
  | Backlog_revision_conflict of { expected : int; actual : int }
  | Owner_present
  | Owner_unavailable of Keeper_owner_registry.lookup_error
  | Registry_lane_present
  | Path_present of string
  | Path_unreadable of string * Unix.error
  | Corrupt_sibling of Keeper_shutdown_store.corrupt_record
  | Unfinished_sibling of Operation_id.t
  | Admission_owned_by_other of Operation_id.t

let error_to_string = function
  | Invalid_request detail -> "invalid absence acknowledgement: " ^ detail
  | Store_error error -> Keeper_shutdown_store.error_to_string error
  | Ineligible_operation -> "only a finalized retained owner with no pending completion or in-flight turn can be acknowledged"
  | Outstanding_recorded_tasks ids -> "unsettled recorded shutdown tasks: " ^ String.concat "," ids
  | Outstanding_tasks ids -> "outstanding Keeper tasks: " ^ String.concat "," ids
  | Outstanding_chat_operations ids -> "outstanding Keeper chat operations: " ^
      String.concat "," (List.map Keeper_chat_operation.Operation_id.to_string ids)
  | Outstanding_semantic_executions ids -> "outstanding Keeper semantic executions: " ^
      String.concat "," (List.map (fun id -> Yojson.Safe.to_string (Keeper_execution_scope_id.to_json id)) ids)
  | Chat_operations_unavailable error -> Keeper_chat_operation_store.error_to_string error
  | Backlog_unavailable detail -> "authoritative backlog unavailable: " ^ detail
  | Backlog_revision_conflict { expected; actual } ->
    Printf.sprintf "backlog revision conflict: expected %d, actual %d" expected actual
  | Owner_present -> "Keeper owner still exists"
  | Owner_unavailable error -> Keeper_owner_registry.lookup_error_to_string error
  | Registry_lane_present -> "Keeper registry lane still exists"
  | Path_present path -> "Keeper path is not physically absent: " ^ path
  | Path_unreadable (path, error) -> path ^ ": " ^ Unix.error_message error
  | Corrupt_sibling record -> "corrupt shutdown inventory: " ^ record.path
  | Unfinished_sibling id -> "unfinished shutdown sibling: " ^ Operation_id.to_string id
  | Admission_owned_by_other id -> "shutdown admission belongs to " ^ Operation_id.to_string id
;;

let require_physical_absence path =
  match Unix.lstat path with
  | _ -> Error (Path_present path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (error, _, _) -> Error (Path_unreadable (path, error))
;;

let require_absent_identity ~config ~keeper_name =
  let base_path = config.Workspace.base_path in
  let* () =
    match Keeper_owner_registry.get ~base_path ~keeper_name with
    | Error (Keeper_owner_registry.Owner_not_found _) -> Ok ()
    | Error error -> Error (Owner_unavailable error)
    | Ok _ -> Error Owner_present
  in
  let* () = match Keeper_registry.get ~base_path keeper_name with
    | None -> Ok () | Some _ -> Error Registry_lane_present in
  let* () = require_physical_absence
      (Keeper_types_profile.keeper_meta_path config keeper_name) in
  require_physical_absence
    (Filename.concat (Config_dir_resolver.keepers_dir_for_base_path ~base_path)
       (keeper_name ^ ".toml"))
;;

let require_settled_inventory ~operation_id inventory =
  List.fold_left (fun result entry ->
    let* () = result in
    match entry with
    | Keeper_shutdown_store.Corrupt_record record -> Error (Corrupt_sibling record)
    | Keeper_shutdown_store.Operation sibling
      when not (Operation_id.equal sibling.operation_id operation_id)
           && requires_admission_fence sibling ->
      Error (Unfinished_sibling sibling.operation_id)
    | Keeper_shutdown_store.Operation _ -> Ok ()) (Ok ()) inventory
;;

let outstanding_task_ids ~config operation backlog =
  List.filter_map (fun (task : Masc_domain.task) ->
    let active_owner = match task.task_status with
      | Masc_domain.Claimed { assignee; _ }
      | Masc_domain.InProgress { assignee; _ }
      | Masc_domain.AwaitingVerification { assignee; _ } -> Some assignee
      | Masc_domain.Todo | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None in
    match active_owner with
    | Some assignee when
        Workspace_task_classify.same_task_actor config assignee operation.keeper_name
        || List.exists (fun id -> String.equal task.id (Keeper_id.Task_id.to_string id))
             operation.owned_task_ids -> Some task.id
    | None | Some _ -> None) backlog.Masc_domain.tasks
;;

let acknowledge_absent_owner_observing ~on_guards_acquired ~config ~keeper_name ~operation_id
    ~expected_revision ~expected_backlog_version ~actor ~reason =
  let* actor = Workspace.validate_agent_name actor
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let reason = String.trim reason in
  let* () =
    if Keeper_types_profile_toml.validate_name keeper_name
       && reason <> "" && expected_revision >= 0 && expected_backlog_version >= 0
    then Ok () else Error (Invalid_request "keeper name, revision, backlog version and reason are required") in
  let base_path = config.Workspace.base_path in
  (* Do not rely on the reservation flag: observing intake and ordinary
     registry registration deliberately proceed despite it. Holding intake
     and the lifecycle key orders both kinds of creator against this commit.
     No owner mailbox command runs while these disk locks are held. *)
  let result, _observed_reservation =
    Keeper_shutdown_intake_fence.run_durable_intake_observing ~base_path ~keeper_name
      (fun _intake_token ->
        Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name (fun () ->
          on_guards_acquired ();
          let locked = Workspace_utils_ops.with_file_lock_r config
              (Workspace_backlog.backlog_lock_path config) (fun () ->
            let decide operation _inventory =
              let* () =
                match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path ~keeper_name with
                | None -> Ok ()
                | Some id when Operation_id.equal id operation_id -> Ok ()
                | Some id -> Error (Admission_owned_by_other id) in
              let* finalization =
                match operation.cleanup_intent.reason, operation.turn_disposition,
                      operation.phase, operation.join_evidence with
                | Operator_stop_retain_meta, No_inflight_turn,
                  Finalized ({ completion = Completion_not_requested; _ } as evidence),
                  Some { terminal = Terminal_stopped; cleanup_error = None; _ } -> Ok evidence
                | _ -> Error Ineligible_operation in
              let unsettled = List.filter (fun id ->
                not (List.exists (Keeper_id.Task_id.equal id) finalization.cleanup.settled_task_ids))
                  operation.owned_task_ids in
              let* () = if unsettled = [] then Ok () else
                Error (Outstanding_recorded_tasks (List.map Keeper_id.Task_id.to_string unsettled)) in
              let* () = require_absent_identity ~config ~keeper_name in
              let* chat_operations = Eio_unix.run_in_systhread
                  ~label:"inspect absent Keeper chat operations" (fun () ->
                    Keeper_chat_operation_store.inspect_outstanding
                      ~path:(Keeper_chat_operation_store.path_for_keeper
                        ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config) ~keeper_name))
                |> Result.map_error (fun error -> Chat_operations_unavailable error) in
              let* () = match chat_operations with
                | Keeper_chat_operation_store.Missing_store -> Ok ()
                | Keeper_chat_operation_store.Stored_operations { chat_operations; semantic_executions } ->
                  if chat_operations <> [] then
                    Error (Outstanding_chat_operations (List.map
                      (fun (op : Keeper_chat_operation.t) -> op.operation_id) chat_operations))
                  else if semantic_executions <> [] then
                    Error (Outstanding_semantic_executions (List.map
                      (fun (execution : Keeper_semantic_execution.t) -> execution.id) semantic_executions))
                  else Ok () in
              let* backlog = Workspace_backlog.read_backlog_r config
                |> Result.map_error (fun detail -> Backlog_unavailable detail) in
              let* () = if backlog.version = expected_backlog_version then Ok () else
                Error (Backlog_revision_conflict { expected = expected_backlog_version; actual = backlog.version }) in
              let outstanding = outstanding_task_ids ~config operation backlog in
              let* () = if outstanding = [] then Ok () else Error (Outstanding_tasks outstanding) in
              Ok { finalization; prior_revision = operation.revision
                 ; prior_updated_at = operation.updated_at
                 ; prior_operation_sha256 = Digestif.SHA256.(to_hex (digest_string
                     (Yojson.Safe.to_string (Keeper_shutdown_store.to_json operation))))
                 ; actor; reason
                 ; acknowledged_at = Masc_domain.now_iso (); backlog_version = backlog.version }
            in
            Keeper_shutdown_store.acknowledge_absent_owner ~config ~keeper_name
              ~operation_id ~expected_revision
              ~check_inventory:(require_settled_inventory ~operation_id) ~decide
            |> Result.map_error (fun error -> Store_error error)
            |> Result.join)
          in
          let* committed = locked
            |> Result.map_error (fun error -> Backlog_unavailable (Masc_domain.masc_error_to_string error))
            |> Result.join in
          (* A later owner/fence is not ours. This only repairs the narrow
             crash window after the acknowledgement CAS and before release. *)
          (match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path ~keeper_name with
           | Some id when Operation_id.equal id operation_id ->
             ignore (Keeper_shutdown_intake_fence.transition_shutdown ~base_path ~keeper_name
               ~from_operation_id:operation_id ~to_operation_id:None)
           | None | Some _ -> ());
          Ok committed))
  in result
;;

let acknowledge_absent_owner ~config ~keeper_name ~operation_id
    ~expected_revision ~expected_backlog_version ~actor ~reason =
  acknowledge_absent_owner_observing ~on_guards_acquired:(fun () -> ())
    ~config ~keeper_name ~operation_id ~expected_revision ~expected_backlog_version ~actor ~reason
;;

module For_testing = struct
  let acknowledge_absent_owner = acknowledge_absent_owner_observing
end
