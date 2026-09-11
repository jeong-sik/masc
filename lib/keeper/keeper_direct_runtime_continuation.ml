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

(* A deferred lane whose failure was the provider throttling must not be
   re-claimed the instant the child exits — that re-issues the same rejected
   call in a tight loop (the chat-lane retry storm of the 2026-09-10 drain
   investigation). The chat lane sleeps its retry by the same capped backoff
   rule the heartbeat lane applies to its cycle, with one difference: the
   chat lane has no cycle cadence, so it passes 0 as the floor and the
   provider's Retry-After hint is authoritative (the shared 60s default still
   guards a missing or garbage hint). Other failure routes stay immediately
   eligible because re-running them is how they recover. *)
let retry_not_before ~now (failure : Agent_core.Error.t) =
  match
    Keeper_runtime_failure_route.route_of_error
      ~boundary:Keeper_runtime_failure_route.Agent_core_execution failure
  with
  | Keeper_runtime_failure_route.Retry_after_observed
      { retry_class =
          ( Keeper_runtime_failure_route.Rate_limited
          | Keeper_runtime_failure_route.Hard_quota
          | Keeper_runtime_failure_route.Capacity_backpressure )
      ; retry_after
      } ->
    Some
      (now
       +. Keeper_runtime_failure_route.retry_backoff_sec
            ~cap_sec:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec
            ~retry_after_hint:retry_after
            ~cadence_sec:0.0)
  | Keeper_runtime_failure_route.Retry_after_observed _
  | Keeper_runtime_failure_route.Rotate_now _
  | Keeper_runtime_failure_route.Exhausted_visible_alive _ -> None

let defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id
    (lane : Keeper_turn_driver.deferred_runtime_lane) =
  let* _, checkpoint = load_owned ~operation_id ~session_dir ~session_id in
  let not_before = retry_not_before ~now:(Time_compat.now ()) lane.failure in
  let* continuation = Semantic.runtime_retry ~not_before ~checkpoint ~assignment_id:lane.assignment_id
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
