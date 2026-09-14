let ( let* ) = Result.bind
module Owner = Keeper_owner_registry
module Checkpoint = Keeper_checkpoint_store
module Snapshot = Keeper_repetition_snapshot
module Semantic = Keeper_semantic_execution
module Native = Keeper_official_client_session_store

type authority = Agent_core of Agent_core.Checkpoint.t | Official_client of Semantic.official_client_checkpoint
type admission = { authority : authority; observed : Semantic.gate_checkpoint }
let checkpoint admission = match admission.authority with Agent_core checkpoint -> Some checkpoint | Official_client _ -> None
let official_client admission = match admission.authority with Official_client checkpoint -> Some checkpoint | Agent_core _ -> None
let official_client_original_turn admission = match admission.observed with
  | Semantic.Official_client checkpoint -> Some checkpoint | Semantic.Agent_core _ -> None
let official_resume_message ~operation_id =
  Printf.sprintf "Continue the unfinished direct operation %s already present in this conversation. Apply any newer user steering, preserve completed tool results, and continue only remaining work. Do not repeat completed effects."
    (Keeper_chat_operation.Operation_id.to_string operation_id)

let prepare_official_resume ~(observed : Semantic.official_client_checkpoint) ~expected =
  match expected with
  | Some ({ Native.phase = Native.Settled settled; _ } as stored)
    when stored.client_kind = observed.client_kind && stored.runtime_id = observed.runtime_id
      && settled.session_id = observed.session_id
      && stored.tool_surface_sha256 = observed.tool_surface_sha256 ->
    (* Queued steering may have advanced this same authoritative conversation.
       Resume its latest settled turn; never substitute another client thread. *)
    Ok { observed with Semantic.turn_id = settled.turn_id }
  | Some _ | None -> Error "original official-client conversation is no longer settled with its admitted tool surface"
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
  | Some (Semantic.Official_client observed) ->
    let* expected = Native.load ~base_path ~keeper_name in
    let* checkpoint = prepare_official_resume ~observed ~expected in
    Ok (Some { authority = Official_client checkpoint; observed = Semantic.Official_client observed })
  | Some (Semantic.Agent_core observed) ->
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
    Ok (Some { authority = Agent_core checkpoint; observed = Semantic.Agent_core observed })

let consume ~base_path ~keeper_name ~operation_id admission =
  Owner.resume_direct_checkpoint ~base_path ~keeper_name ~operation_id
    ~observed:admission.observed |> owner

let defer ~base_path ~keeper_name ~operation_id ~session_dir ~session_id ~checkpoint =
  let* expected_session_id = Keeper_id.Trace_id.of_string session_id in
  let* produced = Checkpoint.exact_snapshot_of_value ~expected_session_id checkpoint
    |> Result.map_error (fun _ -> "producer returned an invalid cooperative checkpoint") in
  let* snapshot = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
    |> Result.map_error (fun _ -> "cooperative checkpoint is unavailable or invalid") in
  let* () = if Keeper_checkpoint_ref.equal (Checkpoint.exact_snapshot_reference produced)
      (Checkpoint.exact_snapshot_reference snapshot) then Ok ()
    else Error "canonical checkpoint is not the checkpoint returned by this turn" in
  let* _ = validate_scope ~operation_id (Checkpoint.exact_snapshot_checkpoint snapshot) in
  let* () = match Checkpoint.retain_exact_snapshot ~session_dir snapshot with
    | Checkpoint.Installed { auxiliary = []; _ } -> Ok ()
    | Checkpoint.Installed _ | Checkpoint.Not_installed _ ->
      Error "cooperative checkpoint retention is not durably confirmed" in
  let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
  match operation with
  | None -> Error "direct operation disappeared before cooperative deferral"
  | Some operation -> Owner.defer_direct_checkpoint ~base_path ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~checkpoint:(Semantic.Agent_core (Checkpoint.exact_snapshot_reference snapshot))
      |> owner |> Result.map (fun _ -> ())

let defer_official ~base_path ~keeper_name ~operation_id ~(settled_session : Native.t) ~frame =
  let* checkpoint = match settled_session.phase, Snapshot.active frame with
    | Native.Settled { session_id; turn_id }, Some scope
      when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) ->
        Ok { Semantic.client_kind = settled_session.client_kind; runtime_id = settled_session.runtime_id;
          session_id; turn_id; tool_surface_sha256 = settled_session.tool_surface_sha256; frame }
    | (Native.Ready | Native.Start _ | Native.Active _ | Native.Turn_inflight _
      | Native.Recovery_required _ | Native.Settled _), (Some _ | None) ->
      Error "official cooperative yield has no settled authority for the original operation" in
  let* current = Native.load ~base_path ~keeper_name in
  let* () = match current with
    | Some current when current = settled_session -> Ok ()
    | Some _ | None -> Error "official-client settlement changed before cooperative retention" in
  let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
  match operation with
  | None -> Error "direct operation disappeared before official cooperative deferral"
  | Some operation -> Owner.defer_direct_checkpoint ~base_path ~keeper_name ~operation_id
      ~execution_digest:operation.execution_digest ~checkpoint:(Semantic.Official_client checkpoint)
      |> owner |> Result.map (fun _ -> ())

module For_testing = struct
  let prepare_official_resume = prepare_official_resume
end
