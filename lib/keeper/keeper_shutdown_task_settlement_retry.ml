open Keeper_shutdown_types
open Result.Syntax
module Store = Keeper_shutdown_store

type error =
  | Invalid_request of string
  | Store_error of Store.error
  | Ineligible_operation
  | Owner_unavailable of Keeper_owner_registry.lookup_error
  | Owner_observation_failed of Keeper_owner.error
  | Owner_stopping
  | Owner_metadata_absent
  | Owner_trace_changed
  | Owner_turn_present
  | Registry_lane_present
  | Lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Admission_mismatch
  | Backlog_unavailable of string
  | Backlog_revision_conflict of { expected : int; actual : int }
  | Corrupt_sibling of Store.corrupt_record
  | Conflicting_sibling of Operation_id.t
  | Unordered_sibling of Operation_id.t
  | New_owned_tasks of string list
  | Recorded_task_changed of string

type preview =
  { operation : Keeper_shutdown_types.t
  ; backlog_version : int
  ; receipted_task_ids : Keeper_id.Task_id.t list
  }

let error_to_string = function
  | Invalid_request detail -> "invalid task-settlement retry: " ^ detail
  | Store_error error -> Store.error_to_string error
  | Ineligible_operation -> "only a dormant no-inflight shutdown blocked at task settlement may be retried"
  | Owner_unavailable error -> Keeper_owner_registry.lookup_error_to_string error
  | Owner_observation_failed error -> Keeper_owner.error_to_string error
  | Owner_stopping -> "the original Keeper owner is stopping"
  | Owner_metadata_absent -> "the original Keeper owner has no metadata"
  | Owner_trace_changed -> "the Keeper trace changed after this shutdown operation"
  | Owner_turn_present -> "the Keeper owner still has an in-flight turn"
  | Registry_lane_present -> "a Keeper lane is registered"
  | Lifecycle_reserved reservation -> Keeper_lifecycle_reservation.snapshot_to_string reservation
  | Admission_mismatch -> "the owner and intake shutdown fences must name this exact operation"
  | Backlog_unavailable detail -> "authoritative backlog unavailable: " ^ detail
  | Backlog_revision_conflict { expected; actual } ->
      Printf.sprintf "backlog version conflict (expected %d, got %d)" expected actual
  | Corrupt_sibling record -> "unreadable shutdown sibling: " ^ Store.error_to_string record.error
  | Conflicting_sibling id -> "a newer or unfinished shutdown sibling exists: " ^ Operation_id.to_string id
  | Unordered_sibling id -> "shutdown sibling order is unobserved or ambiguous: " ^ Operation_id.to_string id
  | New_owned_tasks ids -> "the Keeper owns tasks outside this operation: " ^ String.concat "," ids
  | Recorded_task_changed id -> "recorded task is neither still owned nor released by this operation: " ^ id
;;

let check_siblings (operation : Keeper_shutdown_types.t) inventory =
  let* created = match Masc_domain.parse_iso8601_opt operation.created_at with
    | Some at -> Ok at | None -> Error (Unordered_sibling operation.operation_id) in
  List.fold_left (fun result entry ->
    let* () = result in
    match entry with
    | Store.Corrupt_record record -> Error (Corrupt_sibling record)
    | Store.Operation sibling when Operation_id.equal sibling.operation_id operation.operation_id -> Ok ()
    | Store.Operation sibling ->
        (match Masc_domain.parse_iso8601_opt sibling.created_at with
         | None -> Error (Unordered_sibling sibling.operation_id)
         | Some at when Float.equal at created -> Error (Unordered_sibling sibling.operation_id)
         | Some at when at > created || requires_admission_fence sibling ->
             Error (Conflicting_sibling sibling.operation_id)
         | Some _ -> Ok ())) (Ok ()) inventory
;;

let check_owner ~config ~(owner : Keeper_owner.t)
    ~(observed_meta : Keeper_meta_contract.keeper_meta option)
    (operation : Keeper_shutdown_types.t) =
  let base_path = config.Workspace.base_path in
  let* () = if Store.task_settlement_retry_eligible operation then Ok () else Error Ineligible_operation in
  let* () = match Keeper_lifecycle_reservation.current ~base_path ~keeper_name:operation.keeper_name with
    | None -> Ok () | Some reservation -> Error (Lifecycle_reserved reservation) in
  let* () = match Keeper_registry.get ~base_path operation.keeper_name with
    | None -> Ok () | Some _ -> Error Registry_lane_present in
  let* () = match Keeper_owner.turn_in_flight owner with
    | None -> Ok () | Some _ -> Error Owner_turn_present in
  let* () = match Keeper_shutdown_intake_fence.shutdown_operation_id ~base_path ~keeper_name:operation.keeper_name,
                  Keeper_owner.shutdown_operation_id owner with
    | Some intake, Some held when Operation_id.equal intake operation.operation_id
        && Operation_id.equal held operation.operation_id -> Ok ()
    | (None | Some _), (None | Some _) -> Error Admission_mismatch in
  match observed_meta with
  | None -> Error Owner_metadata_absent
  | Some meta when Keeper_id.Trace_id.equal meta.runtime.trace_id operation.trace_id -> Ok ()
  | Some _ -> Error Owner_trace_changed
;;

let checked_plan ~config ~owner ~observed_meta ~(backlog : Masc_domain.backlog) operation inventory
    : (Store.task_settlement_retry_plan, error) result =
  let* () = check_owner ~config ~owner ~observed_meta operation in
  let* () = check_siblings operation inventory in
  let original id = List.exists (fun task_id -> String.equal id (Keeper_id.Task_id.to_string task_id))
      operation.owned_task_ids in
  let new_owned = List.filter_map (fun (task : Masc_domain.task) ->
    match task.task_status with
    | Masc_domain.Claimed { assignee; _ } | InProgress { assignee; _ }
      when Workspace_task_classify.same_task_actor config assignee operation.keeper_name
           && not (original task.id) -> Some task.id
    | Claimed _ | InProgress _ | AwaitingVerification _ | Todo | Done _ | Cancelled _ -> None)
      backlog.Masc_domain.tasks in
  let* () = if new_owned = [] then Ok () else Error (New_owned_tasks new_owned) in
  (* This is the exact release receipt used by the existing finalizer; no
     failure prose or generic shutdown marker authorizes a released Task. *)
  let receipt = "masc://keeper-shutdown/" ^ Operation_id.to_string operation.operation_id in
  let* receipted = List.fold_left (fun result id ->
    let* held = result in
    let wire = Keeper_id.Task_id.to_string id in
    match List.filter (fun (task : Masc_domain.task) -> String.equal task.id wire) backlog.tasks with
    | [task] ->
        (match task.task_status, task.handoff_context with
         | (Masc_domain.Claimed { assignee; _ } | InProgress { assignee; _ }), _
           when Workspace_task_classify.same_task_actor config assignee operation.keeper_name -> Ok held
         | Todo, Some handoff when List.exists (String.equal receipt) handoff.evidence_refs -> Ok (id :: held)
         | (Claimed _ | InProgress _ | AwaitingVerification _ | Todo | Done _ | Cancelled _), _ ->
             Error (Recorded_task_changed wire))
    | [] | _ :: _ :: _ -> Error (Recorded_task_changed wire)) (Ok []) operation.owned_task_ids in
  Ok { Store.backlog_version = backlog.version; receipted_task_ids = List.rev receipted }
;;

let with_guards ~on_guards_acquired ~config ~keeper_name f =
  if not (Keeper_config.validate_name keeper_name) then Error (Invalid_request "invalid keeper name") else
  let base_path = config.Workspace.base_path in
  let result, _reservation = Keeper_shutdown_intake_fence.run_durable_intake_observing
      ~base_path ~keeper_name (fun _token ->
    Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name (fun () ->
      on_guards_acquired ();
      let* owner = Keeper_owner_registry.get ~base_path ~keeper_name
        |> Result.map_error (fun error -> Owner_unavailable error) in
      (* Mutation authority is mailbox-linearized before taking filesystem
         locks. The lifecycle key keeps metadata writers ordered with it. *)
      let* observed = Keeper_owner.exact_projection owner
        |> Result.map_error (fun error -> Owner_observation_failed error) in
      let* () = if observed.stopping then Error Owner_stopping else Ok () in
      Workspace_utils_ops.with_file_lock_r config (Workspace_backlog.backlog_lock_path config) (fun () ->
        let* backlog = Workspace_backlog.read_backlog_r config
          |> Result.map_error (fun detail -> Backlog_unavailable detail) in
        f owner observed.meta backlog)
      |> Result.map_error (fun error -> Backlog_unavailable (Masc_domain.masc_error_to_string error))
      |> Result.join)) in
  result
;;

let preview ~config ~keeper_name ~operation_id =
  with_guards ~on_guards_acquired:(fun () -> ()) ~config ~keeper_name (fun owner observed_meta backlog ->
    let* operation = Store.load ~config ~keeper_name operation_id
      |> Result.map_error (fun error -> Store_error error) in
    let* siblings = Store.list_for_keeper ~config ~keeper_name
      |> Result.map_error (fun error -> Store_error error) in
    let* plan = checked_plan ~config ~owner ~observed_meta ~backlog operation (List.map (fun op -> Store.Operation op) siblings) in
    Ok { operation; backlog_version = plan.backlog_version; receipted_task_ids = plan.receipted_task_ids })
;;

let prepare_observing ~on_guards_acquired ~config ~keeper_name ~operation_id
    ~expected_revision ~expected_backlog_version =
  if expected_revision < 0 || expected_backlog_version < 0 then
    Error (Invalid_request "revisions must be non-negative") else
  with_guards ~on_guards_acquired ~config ~keeper_name (fun owner observed_meta backlog ->
    let* () = if backlog.Masc_domain.version = expected_backlog_version then Ok () else
      Error (Backlog_revision_conflict { expected = expected_backlog_version; actual = backlog.version }) in
    let* result = Store.prepare_task_settlement_retry ~config ~keeper_name ~operation_id ~expected_revision
        ~decide:(checked_plan ~config ~owner ~observed_meta ~backlog)
      |> Result.map_error (fun error -> Store_error error) |> Result.join in
    match result with
    | Store.Task_settlement_retry_prepared operation -> Ok operation
    | Store.Task_settlement_retry_ineligible _ -> Error Ineligible_operation)
;;

let prepare ~config ~keeper_name ~operation_id ~expected_revision ~expected_backlog_version =
  prepare_observing ~on_guards_acquired:(fun () -> ()) ~config ~keeper_name ~operation_id
    ~expected_revision ~expected_backlog_version
;;

module For_testing = struct let prepare = prepare_observing end
