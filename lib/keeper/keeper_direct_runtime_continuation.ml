let ( let* ) = Result.bind
module Owner = Keeper_owner_registry
module Semantic = Keeper_semantic_execution

type admission =
  { checkpoint : Agent_core.Checkpoint.t
  ; observed : Semantic.runtime_retry
  ; lane : Keeper_turn_driver.deferred_runtime_lane
  }

let checkpoint admission = admission.checkpoint
let lane admission = admission.lane
let owner_result result = Result.map_error Owner.command_error_to_string result

let validate_scope ~operation_id (checkpoint : Agent_core.Checkpoint.t) =
  let* snapshot = Keeper_repetition_scope.load checkpoint.context
    |> Result.map_error Keeper_repetition_snapshot.error_to_string in
  match Keeper_repetition_snapshot.active snapshot with
  | Some scope when Keeper_execution_scope_id.equal scope
      (Keeper_execution_scope_id.direct_operation operation_id) -> Ok ()
  | Some _ | None -> Error "checkpoint does not own this direct operation's active execution scope"

let load_owned ~operation_id ~session_dir ~session_id =
  let* checkpoint, reference =
    Keeper_checkpoint_store.load_agent_core_with_ref ~session_dir ~session_id
    |> Result.map_error (fun _ -> "direct continuation canonical checkpoint is unavailable or invalid") in
  let* () = validate_scope ~operation_id checkpoint in
  Ok (checkpoint, reference)

let load ~base_path ~keeper_name ~operation_id ~session_dir ~session_id =
  let* pending = Owner.direct_runtime_retry ~base_path ~keeper_name ~operation_id |> owner_result in
  match pending with
  | None -> Ok None
  | Some observed ->
    let* checkpoint, reference = load_owned ~operation_id ~session_dir ~session_id in
    if not (Keeper_checkpoint_ref.equal reference observed.checkpoint) then
      Error "direct continuation checkpoint changed; reconciliation is required"
    else
      let lane = Keeper_turn_driver.restore_deferred_runtime_lane
        ~assignment_id:observed.assignment_id ~failed_runtime_id:observed.failed_runtime_id
        ~next_runtime_id:observed.next_runtime_id ~later_runtime_ids:observed.later_runtime_ids
        ~failure:(Agent_core.Error.Internal "restored checkpointed direct runtime continuation")
        |> Keeper_turn_driver.quota_ordered_deferred_runtime_lane ~now:(Time_compat.now ()) in
      Ok (Some {checkpoint; observed; lane})

let consume ~base_path ~keeper_name ~operation_id admission =
  Owner.resume_direct_runtime_retry ~base_path ~keeper_name ~operation_id
    ~observed:admission.observed |> owner_result

let defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id
    (lane : Keeper_turn_driver.deferred_runtime_lane) =
  let* _, checkpoint = load_owned ~operation_id ~session_dir ~session_id in
  let* continuation = Semantic.runtime_retry ~checkpoint ~assignment_id:lane.assignment_id
    ~failed_runtime_id:lane.failed_runtime_id ~next_runtime_id:lane.next_runtime_id
    ~later_runtime_ids:lane.later_runtime_ids in
  let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner_result in
  match operation with
  | None -> Error "direct operation disappeared before continuation commit"
  | Some operation ->
    Owner.defer_direct_runtime_retry ~base_path ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~continuation
    |> owner_result |> Result.map (fun _ -> ())

module For_testing = struct
  let validate_scope = validate_scope
end
