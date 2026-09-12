let ( let* ) = Result.bind
module Semantic = Keeper_semantic_execution
module Owner = Keeper_owner_registry
module Checkpoint = Keeper_checkpoint_store
module Snapshot = Keeper_repetition_snapshot

module Native = Keeper_official_client_session_store
type authority =
  | Agent_core of {checkpoint:Agent_core.Checkpoint.t; source_reference:Keeper_checkpoint_ref.t}
  | Official_client of Semantic.official_client_checkpoint
type admission =
  { authority : authority
  ; mutable transmitted_input : string option
  ; selected : Semantic.gate_resolution
  ; runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  ; resolution : Keeper_event_queue.hitl_resolution
  }
let checkpoint value = match value.authority with Agent_core value -> Some value.checkpoint | Official_client _ -> None
let official_client value = match value.authority with Official_client value -> Some value | Agent_core _ -> None
let runtime_lane value = value.runtime_lane
let resolution value = value.resolution
let source_reference value = match value.authority with Agent_core value -> Some value.source_reference | Official_client _ -> None
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

(* The scope is captured from the admitted session directory, never reconstructed
   from a trace ID or from the operation's untyped source metadata. *)
let session_scope ~config ~session_dir ~session_id =
  let root = Keeper_fs.session_base_dir config in
  let prefix = root ^ Filename.dir_sep in
  if not (String.starts_with ~prefix session_dir) then Error "Gate session is outside the session root"
  else
    let relative = String.sub session_dir (String.length prefix) (String.length session_dir - String.length prefix) in
    match List.rev (String.split_on_char '/' relative) with
    | actual_id :: reversed_scope when actual_id = session_id -> Semantic.session_scope (List.rev reversed_scope)
    | _ -> Error "Gate session directory does not match its checkpoint identity"

let scoped_session_dir ~config scope session_id =
  List.fold_left Filename.concat (Keeper_fs.session_base_dir config)
    (Semantic.session_scope_components scope @ [session_id])

let retained ~config ~operation_id ~session_scope ~reference =
  let session_dir = scoped_session_dir ~config session_scope
    (Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id) in
  let* original = Checkpoint.load_retained_exact_snapshot ~session_dir ~reference
    |> Result.map_error (fun _ -> "original Gate checkpoint is not retained") in
  let checkpoint = Checkpoint.exact_snapshot_checkpoint original in
  let* frame = Keeper_repetition_scope.load checkpoint.context |> Result.map_error Snapshot.error_to_string in
  match Snapshot.active frame with
  | Some scope when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) ->
    Ok original
  | Some _ | None -> Error "retained checkpoint does not own this original direct operation"

let current_with_original ~config ~operation_id ~session_dir ~session_id (waiting : Semantic.gate_wait) =
  let* scope = session_scope ~config ~session_dir ~session_id in
  let* () = if scope = waiting.session_scope then Ok () else Error "Gate session scope changed" in
  let* reference = match waiting.checkpoint with Semantic.Agent_core value -> Ok value
    | Semantic.Official_client _ -> Error "official-client Gate has no Agent Core checkpoint" in
  let* original = retained ~config ~operation_id ~session_scope:waiting.session_scope ~reference in
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

let validate_native ~base_path ~keeper_name checkpoint =
  let* expected = Native.load ~base_path ~keeper_name in
  Native.validate_continuation ~checkpoint ~expected ~client_kind:checkpoint.Semantic.client_kind
    ~runtime_id:checkpoint.runtime_id ~tool_surface_sha256:checkpoint.tool_surface_sha256

let capture_native ~base_path ~keeper_name ~operation_id ~runtime_id ~frame =
  let* stored = Native.load ~base_path ~keeper_name in
  match stored with
  | Some {Native.phase=Native.Settled {session_id; turn_id}; client_kind; runtime_id=actual_runtime;
      tool_surface_sha256; _} when actual_runtime = runtime_id ->
    (match Snapshot.active frame with
     | Some scope when Keeper_execution_scope_id.equal scope (Keeper_execution_scope_id.direct_operation operation_id) ->
       Ok {Semantic.client_kind; runtime_id; session_id; turn_id; tool_surface_sha256; frame}
     | Some _ | None -> Error "official-client Gate yield belongs to another operation")
  | Some _ | None -> Error "official-client Gate yield has no settled native session authority"

let reconcile ~config ~(meta : Keeper_meta_contract.keeper_meta) =
  let base_path = config.Workspace.base_path and keeper_name = meta.name in
  let* waits = Owner.direct_gate_waits ~base_path ~keeper_name |> owner in
  let session_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  List.fold_left (fun result (operation_id, state) ->
    let* () = result in
    match state.Semantic.resolution with
    | Some _ -> Ok ()
    | None ->
      let session_dir = scoped_session_dir ~config state.waiting.session_scope session_id in
      let rec first_resolved = function
        | [] -> Ok ()
        | obligation :: remaining ->
          let* observed = observe ~base_path ~keeper_name obligation in
          match observed.waiting_decision with
          | None -> first_resolved remaining
          | Some decision ->
            let* () = match state.waiting.checkpoint with
              | Semantic.Agent_core _ -> current_with_original ~config ~operation_id ~session_dir ~session_id state.waiting |> Result.map (fun _ -> ())
              | Semantic.Official_client checkpoint -> validate_native ~base_path ~keeper_name checkpoint in
            Owner.resolve_direct_gate ~base_path ~keeper_name ~operation_id
              ~resolution:(resolution_of_observation obligation decision) |> owner |> Result.map (fun _ -> ()) in
      first_resolved state.waiting.obligations) (Ok ()) waits

let suspend ?official_client ?runtime_lane ~config ~keeper_name ~operation_id ~session_dir ~session_id ~approval_ids () =
  let base_path = config.Workspace.base_path in
  let* existing = Owner.direct_gate_obligations ~base_path ~keeper_name ~operation_id |> owner in
  let approval_ids = List.sort_uniq String.compare
    (approval_ids @ List.map (fun (obligation : Semantic.gate_obligation) -> obligation.approval_id) existing) in
  match approval_ids with
  | [] -> Ok false
  | _ ->
    let* runtime_suffix = match runtime_lane with
      | None -> Ok None
      | Some (lane : Keeper_turn_driver.deferred_runtime_lane) ->
        Semantic.runtime_suffix ~assignment_id:lane.assignment_id ~failed_runtime_id:lane.failed_runtime_id
          ~next_runtime_id:lane.next_runtime_id ~later_runtime_ids:lane.later_runtime_ids |> Result.map Option.some in
    let* binding = Semantic.gate_binding ~approval_ids ~obligations:existing ~runtime_suffix in
    let prepare () =
    let* obligations = List.fold_left (fun result approval_id ->
      let* obligations = result in
      let* obligation = bind ~base_path ~keeper_name approval_id in
      if List.mem obligation obligations then Ok obligations else Ok (obligations @ [obligation])) (Ok existing) approval_ids in
    let* session_scope = session_scope ~config ~session_dir ~session_id in
    let* waiting = match official_client with
    | Some (runtime_id, frame) ->
      let* () = match runtime_lane with None -> Ok () | Some _ -> Error "native Gate cannot own an Agent Core runtime checkpoint" in
      let* checkpoint = capture_native ~base_path ~keeper_name ~operation_id ~runtime_id ~frame in
      Semantic.official_client_gate_wait ~checkpoint ~session_scope ~obligations
    | None ->
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
    let reference = Checkpoint.exact_snapshot_reference snapshot in
    (match runtime_lane with
      | None -> Semantic.gate_wait ~checkpoint:reference ~session_scope ~obligations
      | Some (lane : Keeper_turn_driver.deferred_runtime_lane) ->
        let* runtime_retry = Semantic.runtime_retry ~not_before:None ~checkpoint:reference ~assignment_id:lane.assignment_id
          ~failed_runtime_id:lane.failed_runtime_id ~next_runtime_id:lane.next_runtime_id ~later_runtime_ids:lane.later_runtime_ids in
        Semantic.gate_wait_with_runtime_retry ~checkpoint:reference ~session_scope ~obligations ~runtime_retry) in
    let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
    match operation with
    | None -> Error "original Gate operation disappeared"
    | Some operation ->
      let* _ = Owner.defer_direct_gate ~base_path ~keeper_name ~operation_id
        ~execution_digest:operation.execution_digest ~waiting |> owner in
      Ok true in
    match prepare () with
    | Ok _ as confirmed -> confirmed
    | Error diagnostic ->
      let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
      (match operation with
       | None -> Error "original Gate operation disappeared during checkpoint reconciliation"
       | Some operation ->
         let* _ = Owner.defer_direct_gate_reconciliation ~base_path ~keeper_name ~operation_id
           ~execution_digest:operation.execution_digest ~binding ~diagnostic |> owner in
         Log.Keeper.warn "Gate operation retained for checkpoint reconciliation: %s" diagnostic;
         Ok true)

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
    let* authority = match waiting.checkpoint with
    | Semantic.Official_client checkpoint ->
      let* () = validate_native ~base_path ~keeper_name checkpoint in
      Ok (Official_client checkpoint)
    | Semantic.Agent_core reference ->
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
    Ok (Agent_core {checkpoint; source_reference=reference}) in
    let* () = Owner.resume_direct_gate ~base_path ~keeper_name ~operation_id ~waiting ~resolution:selected |> owner in
    let resolution =
      {Keeper_event_queue.approval_id=selected.obligation.approval_id;
       decision=(match selected.decision with Semantic.Gate_approved -> Keeper_event_queue.Hitl_approved
         | Semantic.Gate_denied detail -> Keeper_event_queue.Hitl_rejected detail);
       channel=observed.waiting_request.continuation_channel} in
    let runtime_lane = Option.map (fun (retry : Semantic.runtime_retry) ->
      Keeper_turn_driver.restore_deferred_runtime_lane ~assignment_id:retry.assignment_id
        ~failed_runtime_id:retry.failed_runtime_id ~next_runtime_id:retry.next_runtime_id
        ~later_runtime_ids:retry.later_runtime_ids
        ~failure:(Agent_core.Error.Internal "restored Gate and runtime continuation")
      |> Keeper_turn_driver.quota_ordered_deferred_runtime_lane ~now:(Time_compat.now ())) waiting.runtime_retry in
    Ok (Some {authority; transmitted_input=None; selected; resolution; runtime_lane})

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

let observe_native_input ?blocks ~(prepared : Keeper_gate_replay.model_message) ~config ~user_message admission ~transmitted =
  match admission.authority with
  | Agent_core _ -> Ok ()
  | Official_client _ ->
    let expected = Keeper_gate_replay.user_message_with_hitl_resolution
      ~base_path:config.Workspace.base_path ~user_message (Some admission.resolution) in
    let* () = match admission.selected.decision, prepared.replay_evidence, expected.replay_evidence with
      | Semantic.Gate_approved, Some prepared, Some durable ->
        let input_identity evidence = Keeper_gate_replay.approval_input evidence
          |> Result.map fst |> Result.map_error Keeper_approval_input_admission.error_to_string in
        let* prepared_identity = input_identity prepared in
        let* durable_identity = input_identity durable in
        if prepared_identity <> durable_identity then Error "native Gate input does not identify the durable replay receipt"
        else Ok ()
      | Semantic.Gate_denied _, None, None ->
        if prepared.denied_resolution = Some admission.resolution then Ok ()
        else Error "native Gate input does not identify the admitted denial"
      | Semantic.Gate_approved, None, (None | Some _)
      | Semantic.Gate_approved, Some _, None
      | Semantic.Gate_denied _, Some _, (None | Some _)
      | Semantic.Gate_denied _, None, Some _ ->
        Error "native Gate input has no matching durable resolution evidence" in
    let evidence_present = match blocks with
      | None -> transmitted = prepared.text
      | Some blocks -> List.mem (Agent_core.Types.Text prepared.text) blocks in
    if not evidence_present then Error "native Gate transmitted input differs from its replay evidence"
    else (admission.transmitted_input <- Some transmitted; Ok ())

let complete_native ~config ~keeper_name ~operation_id admission =
  match admission.authority with
  | Agent_core _ -> Ok ()
  | Official_client checkpoint ->
    let* () = validate_native ~base_path:config.Workspace.base_path ~keeper_name checkpoint in
    let* stored = Native.load ~base_path:config.Workspace.base_path ~keeper_name in
    (match admission.transmitted_input, stored with
     | Some _, Some {Native.phase=Native.Settled {turn_id; _}; _} when turn_id <> checkpoint.turn_id ->
       Owner.discharge_direct_gate ~base_path:config.Workspace.base_path ~keeper_name ~operation_id
         ~obligation:admission.selected.obligation |> owner
     | _ -> Error "native Gate continuation has no settled transmitted-input receipt")

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

type pending = Bound_checkpoint of Keeper_checkpoint_ref.t | Bound_official_client of Semantic.official_client_checkpoint | Checkpoint_reconciliation
let pending ~base_path ~keeper_name ~operation_id =
  let* retry = Owner.direct_runtime_retry ~base_path ~keeper_name ~operation_id |> owner in
  match retry with
  | Some retry -> Ok (Some (Bound_checkpoint retry.Semantic.checkpoint))
  | None ->
    let* state = Owner.direct_gate_state ~base_path ~keeper_name ~operation_id |> owner in
    match state with
    | Some state -> Ok (Some (match state.Semantic.waiting.checkpoint with
      | Semantic.Agent_core checkpoint -> Bound_checkpoint checkpoint
      | Semantic.Official_client checkpoint -> Bound_official_client checkpoint))
    | None ->
      let* binding = Owner.direct_gate_binding ~base_path ~keeper_name ~operation_id |> owner in
      if Option.is_none binding then Ok None
      else
        let* operation = Owner.exact_operation ~base_path ~keeper_name operation_id |> owner in
        match operation with
        | Some {Keeper_chat_operation.state=Keeper_chat_operation.Queued; _} -> Ok (Some Checkpoint_reconciliation)
        | Some {Keeper_chat_operation.state=(Keeper_chat_operation.Running _ | Keeper_chat_operation.Succeeded _
            | Keeper_chat_operation.Failed _ | Keeper_chat_operation.Cancelled _); _}
        | None -> Ok None

let record_completed ~config ~keeper_name admission =
  Keeper_approval_queue.ensure_settled_continuation_chat_projection
    ~base_path:config.Workspace.base_path ~keeper_name ~resolution:admission.resolution
