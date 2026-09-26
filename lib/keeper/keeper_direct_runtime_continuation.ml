let ( let* ) = Result.bind
module Owner = Keeper_owner_registry
module Semantic = Keeper_semantic_execution
module Checkpoint = Keeper_checkpoint_store
module Snapshot = Keeper_repetition_snapshot

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
  let* snapshot = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
    |> Result.map_error (fun _ -> "direct continuation canonical checkpoint is unavailable or invalid") in
  let* () = validate_scope ~operation_id (Checkpoint.exact_snapshot_checkpoint snapshot) in
  Ok snapshot

let rec original_prefix original current = match original, current with
  | [], _ -> true
  | first :: rest, current :: tail when first = current -> original_prefix rest tail
  | _ :: _, [] | _ :: _, _ :: _ -> false

let current_assignment keeper_name =
  match Runtime.runtime_id_for_keeper keeper_name with
  | Some assignment -> assignment
  | None -> Runtime.get_default_route ()

let rebase_retry ~keeper_name (retry : Semantic.runtime_retry) =
  let assignment_id = current_assignment keeper_name in
  match Runtime.resolve_assignment assignment_id with
  | `Missing -> Error "current direct retry assignment is unavailable"
  | `Unavailable missing -> Error (Runtime.missing_catalog_model_to_string missing)
  | `Lane lane ->
    (match Runtime_lane.ordered_candidates lane with
     | [] -> Error "current direct retry assignment has no candidates"
     | next_runtime_id :: later_runtime_ids ->
       Semantic.runtime_retry ~not_before:None ~checkpoint:retry.checkpoint
         ~assignment_id ~failed_runtime_id:retry.failed_runtime_id
         ~next_runtime_id ~later_runtime_ids)

let retry_matches_current_assignment ~keeper_name (retry : Semantic.runtime_retry) =
  String.equal (current_assignment keeper_name) retry.assignment_id
  && match Runtime.resolve_assignment retry.assignment_id with
     | `Missing | `Unavailable _ -> false
     | `Lane lane ->
       let declared = Runtime_lane.ordered_candidates lane in
       (* A frozen suffix may have been reordered by quota observations. After
          restart only removed membership proves this suffix invalid; declaration
          order cannot reconstruct the lost dispatch witness. *)
       List.for_all (fun id -> List.exists (String.equal id) declared)
         (retry.next_runtime_id :: retry.later_runtime_ids)

let restored_lane (retry : Semantic.runtime_retry) =
  Keeper_turn_driver.restore_deferred_runtime_lane
    ~assignment_id:retry.assignment_id ~failed_runtime_id:retry.failed_runtime_id
    ~next_runtime_id:retry.next_runtime_id ~later_runtime_ids:retry.later_runtime_ids
    ~failure:(Agent_core.Error.Internal "restored checkpointed direct runtime continuation")

let rec retry_wait ~keeper_name ~dispatch_snapshot ~lane ~observed ~now =
  let current_snapshot = Runtime.keeper_dispatch_snapshot ~keeper_name in
  let dispatch_changed = not (Runtime.same_keeper_dispatch dispatch_snapshot current_snapshot)
    || not (String.equal (current_assignment keeper_name) lane.Keeper_turn_driver.assignment_id) in
  let* retry, next_lane = if dispatch_changed then
      let* retry = rebase_retry ~keeper_name observed in
      Ok (retry, restored_lane retry)
    else Ok (observed, lane) in
  let next_rest = Keeper_turn_driver.deferred_lane_rest ~now next_lane in
  match dispatch_changed, next_rest with
  | false, Keeper_turn_driver.Walk_waits_until _ -> Ok Keeper_owner.Keep_retry_wait
  | (true, Keeper_turn_driver.Walk_waits_until _)
  | (true, Keeper_turn_driver.Walk_head_serving _)
  | (false, Keeper_turn_driver.Walk_head_serving _) ->
    let not_before = match next_rest with
      | Keeper_turn_driver.Walk_waits_until {release_at; _} -> Some release_at
      | Keeper_turn_driver.Walk_head_serving _ -> None in
    let* replacement = Semantic.runtime_retry ~not_before ~checkpoint:retry.checkpoint
      ~assignment_id:retry.assignment_id ~failed_runtime_id:retry.failed_runtime_id
      ~next_runtime_id:retry.next_runtime_id ~later_runtime_ids:retry.later_runtime_ids in
    Ok (Keeper_owner.Update_retry_wait {replacement;
      next_wait=retry_wait ~keeper_name ~dispatch_snapshot:current_snapshot ~lane:next_lane})

let load ~base_path ~keeper_name ~operation_id ~session_dir ~session_id =
  let* pending = Owner.direct_runtime_retry ~base_path ~keeper_name ~operation_id |> owner_result in
  match pending with
  | None -> Ok None
  | Some observed ->
    (* Retention belongs to the reference's original trace in the admitted
       session root, even if the Keeper has since started another trace. *)
    let original_session_dir = Filename.concat (Filename.dirname session_dir)
      (Keeper_id.Trace_id.to_string observed.checkpoint.trace_id) in
    let* original = Checkpoint.load_retained_exact_snapshot ~session_dir:original_session_dir ~reference:observed.checkpoint
      |> Result.map_error (fun _ -> Printf.sprintf
        "original direct runtime checkpoint is unavailable or invalid (operation=%s trace=%s turn=%d sha256=%s); continuation cannot be replayed"
        (Keeper_chat_operation.Operation_id.to_string operation_id)
        (Keeper_id.Trace_id.to_string observed.checkpoint.trace_id)
        observed.checkpoint.turn_count observed.checkpoint.sha256) in
    let original_checkpoint = Checkpoint.exact_snapshot_checkpoint original in
    let* () = validate_scope ~operation_id original_checkpoint in
    let* current = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
      |> Result.map_error (fun _ -> "current direct runtime checkpoint is unavailable") in
    let checkpoint = Checkpoint.exact_snapshot_checkpoint current in
    let* () = if original_prefix original_checkpoint.messages checkpoint.messages then Ok ()
      else Error "current history no longer retains the original direct runtime input and effects" in
    let* source = Keeper_repetition_scope.load original_checkpoint.context
      |> Result.map_error Snapshot.error_to_string in
    let* target = Keeper_repetition_scope.load checkpoint.context
      |> Result.map_error Snapshot.error_to_string in
    let scope = Keeper_execution_scope_id.direct_operation operation_id in
    let* frame = Snapshot.restore_scope ~scope ~source ~target
      |> Result.map_error Snapshot.error_to_string in
    let* messages = match Snapshot.active target with
      | Some active when Keeper_execution_scope_id.equal active scope -> Ok checkpoint.messages
      | Some _ | None ->
        let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner_result in
        (match Option.bind operation (fun operation -> operation.Keeper_chat_operation.input) with
         | None -> Error "original direct runtime operation input is unavailable"
         | Some input ->
           let* decoded = Keeper_chat_operation_payload.input_of_json input in
           let original_request = match decoded.turn_instructions with
             | None -> decoded.message
             | Some instructions -> decoded.message ^ "\n\nOriginal turn instructions:\n" ^ instructions in
           let resume = Agent_core.Types.user_msg (Printf.sprintf
             "Resume the original direct operation %s below. The preceding history includes its completed tool effects and newer shared work. Preserve those results and continue only the remaining work; do not repeat completed writes, Board posts, or peer requests.\nOriginal admitted input:\n%s"
             (Keeper_chat_operation.Operation_id.to_string operation_id)
             original_request) in
           Ok (checkpoint.messages @ [resume])) in
    let context = Agent_core.Context.copy checkpoint.context ~eio:true in
    Keeper_repetition_scope.save context frame;
    let checkpoint = {checkpoint with Agent_core.Checkpoint.context; messages} in
    let* () = match Checkpoint.save_agent_core_if_source ~session_dir
        ~expected_source_ref:(Checkpoint.exact_snapshot_reference current) checkpoint with
      | Checkpoint.Installed {auxiliary=[]; _} -> Ok ()
      | Checkpoint.Installed _ | Checkpoint.Not_installed _ ->
        Error "current-history direct runtime admission is not durably confirmed" in
    (* The checkpoint owns input and effects. A changed assignment owns the
       next dispatch, including when a restart discarded the live witness. *)
    let* dispatch_retry =
      if retry_matches_current_assignment ~keeper_name observed
      then Ok observed else rebase_retry ~keeper_name observed in
    let lane = restored_lane dispatch_retry
      |> Keeper_turn_driver.quota_ordered_deferred_runtime_lane ~now:(Time_compat.now ()) in
    Ok (Some {checkpoint; observed; lane})

let consume ~base_path ~keeper_name ~operation_id admission =
  Owner.resume_direct_runtime_retry ~base_path ~keeper_name ~operation_id
    ~observed:admission.observed |> owner_result

(* A deferred chat retry is claimable when the next dispatch the heartbeat
   would make is (RFC-provider-path-rest §3.4). Both lanes read
   [Keeper_turn_driver.next_dispatch_after_failure], so they answer one failure
   the same way: a suffix whose walk head serves is claimable now; a resting
   head keeps the retry until its release. Claiming a
   retry on a resting path re-issues a refused call in a tight loop (the chat
   lane retry storm of the 2026-09-10 drain investigation). *)
let retry_not_before ~now (lane : Keeper_turn_driver.deferred_runtime_lane) =
  let route =
    Keeper_runtime_failure_route.route_of_error
      ~boundary:Keeper_runtime_failure_route.Agent_core_execution
      lane.failure
  in
  match
    Keeper_turn_driver.next_dispatch_after_failure
      ~now
      ~route
      ~assignment_id:lane.assignment_id
      (Some lane)
  with
  | None | Some (Keeper_turn_driver.Dispatch_now { runtime_id = _ }) -> None
  | Some (Keeper_turn_driver.Wait_until { release_at; waiting_on = _; basis = _ }) ->
    Some release_at

let defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id ~dispatch_snapshot
    (lane : Keeper_turn_driver.deferred_runtime_lane) =
  let* snapshot = load_owned ~operation_id ~session_dir ~session_id in
  let* () = match Checkpoint.retain_exact_snapshot ~session_dir snapshot with
    | Checkpoint.Installed {auxiliary=[]; _} -> Ok ()
    | Checkpoint.Installed _ | Checkpoint.Not_installed _ ->
      Error "direct runtime checkpoint retention is not durably confirmed" in
  let checkpoint = Checkpoint.exact_snapshot_reference snapshot in
  let not_before = retry_not_before ~now:(Time_compat.now ()) lane in
  let* continuation = Semantic.runtime_retry ~not_before ~checkpoint ~assignment_id:lane.assignment_id
    ~failed_runtime_id:lane.failed_runtime_id ~next_runtime_id:lane.next_runtime_id
    ~later_runtime_ids:lane.later_runtime_ids in
  let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner_result in
  match operation with
  | None -> Error "direct operation disappeared before continuation commit"
  | Some operation ->
    Owner.defer_direct_runtime_retry ~base_path ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~continuation
      ~retry_wait:(match not_before with
        | None -> None
        | Some _ -> Some (retry_wait ~keeper_name ~dispatch_snapshot ~lane))
    |> owner_result |> Result.map (fun _ -> ())

module For_testing = struct
  let validate_scope = validate_scope
  let retry_not_before = retry_not_before
  let retry_wait = retry_wait
  let retry_matches_current_assignment = retry_matches_current_assignment
end
