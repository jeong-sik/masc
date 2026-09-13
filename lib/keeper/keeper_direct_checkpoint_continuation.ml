let ( let* ) = Result.bind
module Owner = Keeper_owner_registry
module Checkpoint = Keeper_checkpoint_store
module Snapshot = Keeper_repetition_snapshot

type admission = { checkpoint : Agent_core.Checkpoint.t; observed : Keeper_checkpoint_ref.t }
let checkpoint admission = admission.checkpoint
let owner result = Result.map_error Owner.command_error_to_string result
let validate_scope ~operation_id (checkpoint : Agent_core.Checkpoint.t) =
  let* frame = Keeper_repetition_scope.load checkpoint.context
    |> Result.map_error Snapshot.error_to_string in
  match Snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope
      (Keeper_execution_scope_id.direct_operation operation_id) -> Ok frame
  | Some _ | None -> Error "checkpoint does not own the original direct operation"

let rec original_prefix original current = match original, current with
  | [], _ -> true
  | first :: rest, current :: tail when first = current -> original_prefix rest tail
  | _ :: _, [] | _ :: _, _ :: _ -> false

let load ~base_path ~keeper_name ~operation_id ~session_dir ~session_id =
  let* pending = Owner.direct_checkpoint ~base_path ~keeper_name ~operation_id |> owner in
  match pending with
  | None -> Ok None
  | Some observed ->
    let original_session_dir = Filename.concat (Filename.dirname session_dir)
      (Keeper_id.Trace_id.to_string observed.trace_id) in
    let* original = Checkpoint.load_retained_exact_snapshot ~session_dir:original_session_dir ~reference:observed
      |> Result.map_error (fun _ -> "original cooperative checkpoint is unavailable or invalid") in
    let original_checkpoint = Checkpoint.exact_snapshot_checkpoint original in
    let* source = validate_scope ~operation_id original_checkpoint in
    let* current = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
      |> Result.map_error (fun _ -> "current canonical checkpoint is unavailable") in
    let checkpoint = Checkpoint.exact_snapshot_checkpoint current in
    let* () = if original_prefix original_checkpoint.messages checkpoint.messages then Ok ()
      else Error "current history does not retain the original input and completed effects" in
    let* target = Keeper_repetition_scope.load checkpoint.context |> Result.map_error Snapshot.error_to_string in
    let* frame = Snapshot.restore_scope ~scope:(Keeper_execution_scope_id.direct_operation operation_id)
      ~source ~target |> Result.map_error Snapshot.error_to_string in
    let context = Agent_core.Context.copy checkpoint.context ~eio:true in
    Keeper_repetition_scope.save context frame;
    (* Newer user steering remains in canonical history. Restore execution
       ownership without appending the original input or replaying tool calls. *)
    let checkpoint = { checkpoint with Agent_core.Checkpoint.context } in
    let* () = match Checkpoint.save_agent_core_if_source ~session_dir
        ~expected_source_ref:(Checkpoint.exact_snapshot_reference current) checkpoint with
      | Checkpoint.Installed { auxiliary = []; _ } -> Ok ()
      | Checkpoint.Installed _ | Checkpoint.Not_installed _ ->
        Error "cooperative continuation admission is not durably confirmed" in
    Ok (Some { checkpoint; observed })

let consume ~base_path ~keeper_name ~operation_id admission =
  Owner.resume_direct_checkpoint ~base_path ~keeper_name ~operation_id
    ~observed:admission.observed |> owner

let defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id =
  let* snapshot = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
    |> Result.map_error (fun _ -> "cooperative checkpoint is unavailable or invalid") in
  let* _ = validate_scope ~operation_id (Checkpoint.exact_snapshot_checkpoint snapshot) in
  let* () = match Checkpoint.retain_exact_snapshot ~session_dir snapshot with
    | Checkpoint.Installed { auxiliary = []; _ } -> Ok ()
    | Checkpoint.Installed _ | Checkpoint.Not_installed _ ->
      Error "cooperative checkpoint retention is not durably confirmed" in
  let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
  match operation with
  | None -> Error "direct operation disappeared before cooperative deferral"
  | Some operation -> Owner.defer_direct_checkpoint ~base_path ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~checkpoint:(Checkpoint.exact_snapshot_reference snapshot)
      |> owner |> Result.map (fun _ -> ())
