let ( let* ) = Result.bind
module Semantic = Keeper_semantic_execution
module Owner = Keeper_owner_registry
module Checkpoint = Keeper_checkpoint_store
module Snapshot = Keeper_repetition_snapshot

type admission =
  { checkpoint : Agent_core.Checkpoint.t
  ; source_reference : Keeper_checkpoint_ref.t
  ; waiting : Semantic.gate_wait
  ; selected : Semantic.gate_resolution
  ; resolution : Keeper_event_queue.hitl_resolution
  }
let checkpoint value = value.checkpoint
let resolution value = value.resolution
let source_reference value = value.source_reference
let owner result = Result.map_error Owner.command_error_to_string result

let observe ~base_path ~keeper_name (obligation : Semantic.gate_obligation) =
  let* observed = Keeper_approval_queue.observe_waiting_request ~base_path ~id:obligation.approval_id
    |> Result.map_error Keeper_approval_queue.storage_error_to_string in
  match observed with
  | None -> Error "Gate obligation has no durable authority"
  | Some observed ->
    let request = observed.waiting_request in
    if request.keeper_name <> keeper_name || request.tool_name <> obligation.tool_name
       || request.input_hash <> obligation.input_hash then Error "Gate obligation identity changed"
    else Ok observed

let bind ~base_path ~keeper_name approval_id =
  let* observed = Keeper_approval_queue.observe_waiting_request ~base_path ~id:approval_id
    |> Result.map_error Keeper_approval_queue.storage_error_to_string in
  match observed with
  | None -> Error "deferred Gate request is absent from durable authority"
  | Some observed ->
    let request = observed.waiting_request in
    if request.keeper_name <> keeper_name then Error "Gate request belongs to another Keeper"
    else Semantic.gate_obligation ~approval_id ~tool_name:request.tool_name ~input_hash:request.input_hash

let rec original_prefix original current = match original, current with
  | [], _ -> true
  | first :: rest, current :: tail when first = current -> original_prefix rest tail
  | _ :: _, [] | _ :: _, _ :: _ -> false

let retained ~config ~operation_id (waiting : Semantic.gate_wait) =
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config)
    (Keeper_id.Trace_id.to_string waiting.checkpoint.trace_id) in
  let* original = Checkpoint.load_retained_exact_snapshot ~session_dir ~reference:waiting.checkpoint
    |> Result.map_error (fun _ -> "original Gate checkpoint is not retained") in
  let checkpoint = Checkpoint.exact_snapshot_checkpoint original in
  let* frame = Keeper_repetition_scope.load checkpoint.context |> Result.map_error Snapshot.error_to_string in
  match Snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) ->
    Ok original
  | Some _ | None -> Error "retained checkpoint does not own this original direct operation"

let current_with_original ~config ~operation_id ~session_dir ~session_id waiting =
  let* original = retained ~config ~operation_id waiting in
  let* current = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
    |> Result.map_error (fun _ -> "current Keeper checkpoint is unavailable") in
  let original_checkpoint = Checkpoint.exact_snapshot_checkpoint original in
  let current_checkpoint = Checkpoint.exact_snapshot_checkpoint current in
  if not (original_prefix original_checkpoint.messages current_checkpoint.messages) then
    Error "current history no longer retains the exact original Gate input; reconciliation is required"
  else
    let* source = Keeper_repetition_scope.load original_checkpoint.context |> Result.map_error Snapshot.error_to_string in
    let* target = Keeper_repetition_scope.load current_checkpoint.context |> Result.map_error Snapshot.error_to_string in
    let* frame = Snapshot.restore_scope ~scope:(Keeper_execution_scope_id.direct_operation operation_id) ~source ~target
      |> Result.map_error Snapshot.error_to_string in
    let context = Agent_core.Context.copy current_checkpoint.context ~eio:true in
    Keeper_repetition_scope.save context frame;
    Ok (current, {current_checkpoint with context})

let resolution_of_observation obligation = function
  | Keeper_approval_queue_rules_types.Decision.Approve ->
    {Semantic.obligation; decision=Semantic.Gate_approved}
  | Keeper_approval_queue_rules_types.Decision.Reject detail ->
    {Semantic.obligation; decision=Semantic.Gate_denied detail}

let reconcile ~config ~(meta : Keeper_meta_contract.keeper_meta) =
  let base_path = config.Workspace.base_path and keeper_name = meta.name in
  let* waits = Owner.direct_gate_waits ~base_path ~keeper_name |> owner in
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let session_dir = Filename.concat (Keeper_fs.session_base_dir config) session_id in
  List.fold_left (fun result (operation_id, state) ->
    let* () = result in
    match state.Semantic.resolution with
    | Some _ -> Ok ()
    | None ->
      let rec first_resolved = function
        | [] -> Ok ()
        | obligation :: remaining ->
          let* observed = observe ~base_path ~keeper_name obligation in
          match observed.waiting_decision with
          | None -> first_resolved remaining
          | Some decision ->
            let* _ = current_with_original ~config ~operation_id ~session_dir ~session_id state.waiting in
            Owner.resolve_direct_gate ~base_path ~keeper_name ~operation_id
              ~resolution:(resolution_of_observation obligation decision) |> owner |> Result.map (fun _ -> ()) in
      first_resolved state.waiting.obligations) (Ok ()) waits

let suspend ~config ~keeper_name ~operation_id ~session_dir ~session_id ~approval_ids =
  let base_path = config.Workspace.base_path in
  let* existing = Owner.direct_gate_obligations ~base_path ~keeper_name ~operation_id |> owner in
  let* obligations = List.fold_left (fun result approval_id ->
    let* obligations = result in
    let* obligation = bind ~base_path ~keeper_name approval_id in
    if List.mem obligation obligations then Ok obligations else Ok (obligations @ [obligation])) (Ok existing) approval_ids in
  match obligations with
  | [] -> Ok false
  | _ ->
    let* snapshot = Checkpoint.load_agent_core_exact_snapshot ~session_dir ~session_id
      |> Result.map_error (fun _ -> "Gate yield checkpoint is unavailable") in
    let checkpoint = Checkpoint.exact_snapshot_checkpoint snapshot in
    let* frame = Keeper_repetition_scope.load checkpoint.context |> Result.map_error Snapshot.error_to_string in
    let* () = match Snapshot.active frame with
      | Some scope when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) -> Ok ()
      | Some _ | None -> Error "Gate yield checkpoint belongs to another operation" in
    let* () = match Checkpoint.retain_exact_snapshot ~session_dir snapshot with
      | Checkpoint.Installed {auxiliary=[]; _} -> Ok ()
      | Checkpoint.Installed _ | Checkpoint.Not_installed _ -> Error "Gate checkpoint retention is not durably confirmed" in
    let* waiting = Semantic.gate_wait ~checkpoint:(Checkpoint.exact_snapshot_reference snapshot) ~obligations in
    let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
    match operation with
    | None -> Error "original Gate operation disappeared"
    | Some operation ->
      let* _ = Owner.defer_direct_gate ~base_path ~keeper_name ~operation_id
        ~execution_digest:operation.execution_digest ~waiting |> owner in
      Ok true

let denial_input (selected : Semantic.gate_resolution) =
  match selected.decision with
  | Semantic.Gate_approved -> Error "approval requires durable replay evidence"
  | Semantic.Gate_denied detail ->
    let encoded = Yojson.Safe.to_string (`Assoc ["approval_id", `String selected.obligation.approval_id;
      "tool_name", `String selected.obligation.tool_name; "input_hash", `String selected.obligation.input_hash;
      "denied", `String detail]) in
    let evidence_fingerprint = Digestif.SHA256.(digest_string encoded |> to_hex) in
    let* identity = Keeper_approval_input_admission.identity
      ~approval_id:selected.obligation.approval_id ~evidence_fingerprint
      |> Result.map_error Keeper_approval_input_admission.error_to_string in
    Ok (identity, Agent_core.Types.user_msg
      ("Gate request " ^ selected.obligation.approval_id ^ " was denied: " ^ detail))

let load_ready ~config ~(meta : Keeper_meta_contract.keeper_meta) ~operation_id ~session_dir =
  let base_path = config.Workspace.base_path and keeper_name = meta.name in
  let* state = Owner.direct_gate_state ~base_path ~keeper_name ~operation_id |> owner in
  match state with
  | None -> Ok None
  | Some {resolution=None; _} -> Error "unresolved Gate operation was claimed"
  | Some {waiting; resolution=Some selected} ->
    let* observed = observe ~base_path ~keeper_name selected.obligation in
    let* () = match observed.waiting_decision with
      | Some decision when resolution_of_observation selected.obligation decision = selected -> Ok ()
      | Some _ | None -> Error "durable Gate resolution changed before resume" in
    let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let* source, checkpoint = current_with_original ~config ~operation_id ~session_dir ~session_id waiting in
    let* () = match Checkpoint.save_agent_core_if_source ~session_dir
        ~expected_source_ref:(Checkpoint.exact_snapshot_reference source) checkpoint with
      | Checkpoint.Installed {auxiliary=[]; _} -> Ok ()
      | Checkpoint.Installed _ | Checkpoint.Not_installed _ -> Error "current-history Gate admission is not durably confirmed" in
    let* checkpoint = match selected.decision with
      | Semantic.Gate_approved -> Ok checkpoint
      | Semantic.Gate_denied _ ->
        let* identity, message = denial_input selected in
        Keeper_approval_input_checkpoint.admit ~session_dir ~identity ~message checkpoint in
    let* () = Owner.resume_direct_gate ~base_path ~keeper_name ~operation_id ~waiting ~resolution:selected |> owner in
    let resolution =
      {Keeper_event_queue.approval_id=selected.obligation.approval_id;
       decision=(match selected.decision with Semantic.Gate_approved -> Keeper_event_queue.Hitl_approved
         | Semantic.Gate_denied detail -> Keeper_event_queue.Hitl_rejected detail);
       channel=observed.waiting_request.continuation_channel} in
    Ok (Some {checkpoint; source_reference=waiting.checkpoint; waiting; selected; resolution})

let discharge ~config ~keeper_name ~operation_id ~user_message ~checkpoint admission =
  let* identity, message = match admission.selected.decision with
    | Semantic.Gate_denied _ -> denial_input admission.selected
    | Semantic.Gate_approved ->
      let model_message = Keeper_gate_replay.user_message_with_hitl_resolution
        ~base_path:config.Workspace.base_path ~user_message (Some admission.resolution) in
      (match model_message.replay_evidence with
       | None -> Error "Gate replay has not produced durable model evidence"
       | Some evidence -> Keeper_gate_replay.approval_input evidence
           |> Result.map_error Keeper_approval_input_admission.error_to_string) in
  if not (Keeper_approval_input_admission.contains ~identity ~message checkpoint.Agent_core.Checkpoint.messages)
  then Error "Gate evidence is not present in the admitted checkpoint"
  else Owner.discharge_direct_gate ~base_path:config.Workspace.base_path ~keeper_name ~operation_id
    ~obligation:admission.selected.obligation |> owner

let load ~config ~meta ~operation_id ~session_dir =
  match load_ready ~config ~meta ~operation_id ~session_dir with
  | Ok _ as ready -> ready
  | Error detail ->
    let base_path = config.Workspace.base_path in
    let keeper_name = meta.Keeper_meta_contract.name in
    let* state = Owner.direct_gate_state ~base_path ~keeper_name ~operation_id |> owner in
    (match state with
     | None -> Error detail
     | Some state ->
       let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
       match operation with
       | None -> Error "Gate operation disappeared during admission"
       | Some operation ->
         let* _ = Owner.defer_direct_gate ~base_path ~keeper_name ~operation_id
           ~execution_digest:operation.execution_digest ~waiting:state.waiting |> owner in
         Error detail)
