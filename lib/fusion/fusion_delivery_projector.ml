type projection_error =
  | Invalid_request_id of string
  | Obligation_unavailable of Fusion_delivery_obligation.error
  | Identity_mismatch of string
  | Non_durable_settlement
  | Ambiguous_settlement
  | Nonterminal_status of Keeper_msg_async.request_status
  | Evidence_invalid of string
  | Projection_failed of string
  | Obligation_removal_failed of Fusion_delivery_obligation.error

let projection_error_to_string = function
  | Invalid_request_id detail -> "invalid Fusion request id: " ^ detail
  | Obligation_unavailable error
  | Obligation_removal_failed error ->
    Fusion_delivery_obligation.error_to_string error
  | Identity_mismatch detail -> "Fusion delivery identity mismatch: " ^ detail
  | Non_durable_settlement ->
    "Fusion settlement is visible but not durably canonical"
  | Ambiguous_settlement ->
    "Fusion settlement disagrees with canonical request truth"
  | Nonterminal_status status ->
    "Fusion request is not terminal: " ^ Keeper_msg_async.status_to_string status
  | Evidence_invalid detail -> "invalid Fusion deliberation evidence: " ^ detail
  | Projection_failed detail -> "Fusion terminal projection failed: " ^ detail
;;


let ( let* ) = Result.bind

let request_id_of_entry (entry : Keeper_msg_async.entry) =
  Keeper_chat_delivery_identity.Request_id.of_string entry.request_id
  |> Result.map_error (fun detail -> Invalid_request_id detail)
;;

let validate_identity
      (entry : Keeper_msg_async.entry)
      (obligation : Fusion_delivery_obligation.t)
  =
  let payload = obligation.payload in
  if not (String.equal entry.request_id
            (Keeper_chat_delivery_identity.Request_id.to_string obligation.request_id))
  then Error (Identity_mismatch "request_id differs from the obligation")
  else if not (String.equal entry.keeper_name payload.keeper_name)
  then Error (Identity_mismatch "keeper_name differs from the obligation")
  else if not (String.equal entry.submitted_by payload.submitted_by)
  then Error (Identity_mismatch "submitted_by differs from the obligation")
  else Ok ()
;;

let ensure_registry_entry ~registry obligation =
  let run_id =
    Keeper_chat_delivery_identity.Request_id.to_string obligation.Fusion_delivery_obligation.request_id
  in
  match Fusion_run_registry.get registry ~run_id with
  | Some _ -> ()
  | None ->
    Fusion_run_registry.register_running registry ~run_id
      ~keeper:obligation.payload.keeper_name ~preset:obligation.payload.preset
      ~topology:obligation.payload.topology ~started_at:obligation.accepted_at;
    Fusion_sink.broadcast_run_status ~registry ~run_id
;;

(* lifecycle 상태를 typed 실패로 옮긴다. 문자열 code 로 접지 않는 이유는 wake 가
   보낼 terminal 이 사유에 달려 있기 때문이다 — 취소는 [Fusion_cancelled] 로 가야
   키퍼가 "심의가 실패했다" 와 "심의가 중단됐다" 를 구분한다. *)
let failure_of_status : Keeper_msg_async.request_status -> Fusion_sink.delivery_failure option
  = function
  | Keeper_msg_async.Done { ok = false; body; _ } ->
    Some (Fusion_sink.Computation_failed body)
  | Keeper_msg_async.Lost { reason } -> Some (Fusion_sink.Lost reason)
  | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
    Some (Fusion_sink.Cancelled { reason; cancelled_by })
  | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
    Some (Fusion_sink.Persistence_failed { attempted_status; reason })
  | Keeper_msg_async.Done { ok = true; _ }
  | Keeper_msg_async.Queued
  | Keeper_msg_async.Running
  | Keeper_msg_async.Cancelling _ -> None
;;

let project_entry ~registry ~base_path (entry : Keeper_msg_async.entry) =
  let* request_id = request_id_of_entry entry in
  let* obligation =
    Fusion_delivery_obligation.load ~base_path ~request_id
    |> Result.map_error (fun error -> Obligation_unavailable error)
  in
  let* () = validate_identity entry obligation in
  ensure_registry_entry ~registry obligation;
  let payload = obligation.payload in
  let request : Fusion_types.fusion_request =
    { run_id = entry.request_id
    ; keeper = payload.keeper_name
    ; prompt = payload.prompt
    ; preset = payload.preset
    ; web_tools = payload.web_tools
    ; depth = Fusion_types.Fusion_depth.Top
    ; trigger = Fusion_types.Explicit_tool_call
    }
  in
  let* () =
    match entry.status with
    | Keeper_msg_async.Done { ok = true; data = Some data; _ } ->
      let* evidence =
        Fusion_types.deliberation_evidence_of_yojson data
        |> Result.map_error (fun detail -> Evidence_invalid detail)
      in
      if not (String.equal evidence.question payload.prompt)
      then Error (Identity_mismatch "evidence question differs from accepted prompt")
      else
        Fusion_orchestrator.project ~registry ~base_dir:base_path
          ~topology:payload.topology ~channel:payload.channel ~request evidence
        |> Result.map_error (fun detail -> Projection_failed detail)
    | Keeper_msg_async.Done { ok = true; data = None; _ } ->
      (* A durably canonical [Done] without deliberation evidence can never
         become projectable — the settlement is terminal and immutable, so
         retaining the obligation would retry forever on every startup.
         Remediate by delivering a typed failure through the same fail-closed
         sink and then clearing the obligation (a failed failure-projection
         still retains it). *)
      Fusion_sink.emit_failure ~registry ~base_dir:base_path
        ~keeper:payload.keeper_name ~run_id:entry.request_id ~channel:payload.channel
        ~failure:Fusion_sink.Evidence_unavailable
      |> Result.map_error (fun detail -> Projection_failed detail)
    | status ->
      (match failure_of_status status with
       | Some failure ->
         Fusion_sink.emit_failure ~registry ~base_dir:base_path
           ~keeper:payload.keeper_name ~run_id:entry.request_id
           ~channel:payload.channel ~failure
         |> Result.map_error (fun detail -> Projection_failed detail)
       | None -> Error (Nonterminal_status status))
  in
  Fusion_delivery_obligation.remove_delivered ~base_path ~identity:obligation
  |> Result.map_error (fun error -> Obligation_removal_failed error)
;;

let on_worker_settled ?(registry = Fusion_run_registry.global ()) ~base_path = function
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Durable; _ } ->
    (match project_entry ~registry ~base_path entry with
     | Ok () -> ()
     | Error error ->
       Log.Keeper.error ~keeper_name:entry.keeper_name
         "fusion delivery retained request_id=%s error=%s"
         entry.request_id (projection_error_to_string error))
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Volatile_persistence_failure; _ } ->
    Log.Keeper.error ~keeper_name:entry.keeper_name
      "fusion delivery retained request_id=%s error=%s"
      entry.request_id (projection_error_to_string Non_durable_settlement)
  | Keeper_msg_async.Settlement_projection_error { attempted_entry; _ } ->
    Log.Keeper.error ~keeper_name:attempted_entry.keeper_name
      "fusion delivery retained request_id=%s error=%s"
      attempted_entry.request_id (projection_error_to_string Ambiguous_settlement)
;;

type recovery_record_error =
  { request_id : string option
  ; detail : string
  }

type recovery_report =
  { examined : int
  ; projected : int
  ; pending : int
  ; record_errors : recovery_record_error list
  ; staging_cleanup : Fs_compat.atomic_orphan_cleanup_report
  }

(* [()] closes the argument list so [?registry] can be erased: OCaml only
   drops an optional when a positional argument follows it, and every other
   parameter here is labelled. *)
let recover_startup ?(registry = Fusion_run_registry.global ()) ~base_path () =
  let* staging_cleanup =
    Fusion_delivery_obligation.cleanup_staging_for_startup ~base_path
  in
  let* inventory = Fusion_delivery_obligation.inventory ~base_path in
  let staging_errors =
    List.map
      (fun (failure : Fs_compat.atomic_orphan_cleanup_failure) ->
         { request_id = None
         ; detail = Fs_compat.atomic_orphan_cleanup_failure_to_string failure
         })
      staging_cleanup.failures
  in
  let malformed_errors =
    List.map
      (fun (error : Fusion_delivery_obligation.record_failure) ->
         { request_id = None; detail = error.path ^ ": " ^ error.detail })
      inventory.record_failures
  in
  let step (projected, pending, errors) obligation =
    let request_id =
      Keeper_chat_delivery_identity.Request_id.to_string obligation.Fusion_delivery_obligation.request_id
    in
    match
      Keeper_msg_async.load_canonical_durable_terminal ~base_path
        ~caller:obligation.payload.submitted_by request_id
    with
    | Ok proof ->
      let entry = Keeper_msg_async.durable_terminal_entry proof in
      (match project_entry ~registry ~base_path entry with
       | Ok () -> projected + 1, pending, errors
       | Error error ->
         ( projected
         , pending + 1
         , { request_id = Some request_id; detail = projection_error_to_string error }
           :: errors ))
    | Error error ->
      ( projected
      , pending + 1
      , { request_id = Some request_id
        ; detail = Keeper_msg_async.canonical_terminal_error_to_string error
        }
        :: errors )
  in
  let projected, pending, errors =
    List.fold_left step
      (0, List.length staging_cleanup.failures, staging_errors @ malformed_errors)
      inventory.obligations
  in
  Ok
    { examined = List.length inventory.obligations + List.length inventory.record_failures
    ; projected
    ; pending = pending + List.length inventory.record_failures
    ; record_errors = List.rev errors
    ; staging_cleanup
    }
;;
