let ( let* ) = Result.bind

type request =
  | Cancel of
      { expected_revision : int64
      ; queue_index : int
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { expected_revision : int64
      ; queue_index : int
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { expected_revision : int64
      ; queue_index : int
      ; urgency : Keeper_event_queue.urgency
      }

let pending_source_at ~queue_index pending =
  List.nth_opt (Keeper_event_queue.to_list pending) queue_index
;;

let transition_result_json = function
  | Keeper_registry_event_queue.Transition_applied receipt ->
    `Assoc
      [ "status", `String "applied"
      ; "transition_id", `String receipt.transition_id
      ]
  | Keeper_registry_event_queue.Transition_already_applied receipt ->
    `Assoc
      [ "status", `String "already_applied"
      ; "transition_id", `String receipt.transition_id
      ]
  | Keeper_registry_event_queue.Transition_committed_followup_failed
      { receipt; stage; detail } ->
    `Assoc
      [ "status", `String "committed_followup_failed"
      ; "transition_id", `String receipt.transition_id
      ; ( "stage"
        , `String
            (match stage with
             | `Checkpoint -> "checkpoint"
             | `Wal_compaction -> "wal_compaction"
             | `Projection -> "projection") )
      ; "detail", `String detail
      ]
;;

let transition_receipt = function
  | Keeper_registry_event_queue.Transition_applied receipt
  | Keeper_registry_event_queue.Transition_already_applied receipt
  | Keeper_registry_event_queue.Transition_committed_followup_failed
      { receipt; _ } ->
    receipt
;;

type prepared_cancellation =
  { cancellation : Keeper_registry_event_queue.accepted_cancellation
  ; applied_at : float
  }

type prepared_transfer =
  { transfer : Keeper_registry_event_queue.accepted_transfer
  ; applied_at : float
  }

let resolve_pending_source
      ~queue_state
      ~expected_revision
      ~queue_index
  =
  let observed_revision = Keeper_event_queue_state.revision queue_state in
  if not (Int64.equal expected_revision observed_revision)
  then
    Error
      (Printf.sprintf
         "event queue revision mismatch (expected=%Ld observed=%Ld)"
         expected_revision
         observed_revision)
  else
    match
      pending_source_at
        ~queue_index
        (Keeper_event_queue_state.pending queue_state)
    with
    | Some source -> Ok source
    | None -> Error "event queue selection is no longer pending"
;;

let prior_cancellation_for_request
      ~queue_state
      ~expected_revision
      ~operator_operation_id
      ~reason
  =
  match
    Keeper_event_queue_state.prior_disposition_by_operation_id
      operator_operation_id
      queue_state
  with
  | None -> Ok None
  | Some receipt ->
    (match receipt.transition with
     | Keeper_event_queue_state.Cancel_accepted cancellation
       when Int64.equal cancellation.source_revision expected_revision
            && String.equal cancellation.reason reason ->
       Ok (Some { cancellation; applied_at = receipt.applied_at })
     | Keeper_event_queue_state.Cancel_accepted _
     | Keeper_event_queue_state.Transfer_accepted _
     | Keeper_event_queue_state.Ack_source_terminal _ ->
       Error
         ("event queue operator operation ID conflicts with cancellation request: "
          ^ operator_operation_id))
;;

let fresh_cancellation_for_request
      ~queue_state
      ~owner_nonce
      ~expected_revision
      ~queue_index
      ~operator_operation_id
      ~reason
  =
  let* source =
    resolve_pending_source
      ~queue_state
      ~expected_revision
      ~queue_index
  in
  let cancellation : Keeper_registry_event_queue.accepted_cancellation =
    { source
    ; source_revision = expected_revision
    ; owner_nonce
    ; operator_operation_id
    ; reason
    }
  in
  Ok { cancellation; applied_at = Time_compat.now () }
;;

let prior_transfer_for_request
      ~queue_state
      ~keeper_name
      ~expected_revision
      ~operator_operation_id
      ~target_keeper
  =
  match
    Keeper_event_queue_state.prior_disposition_by_operation_id
      operator_operation_id
      queue_state
  with
  | None -> Ok None
  | Some receipt ->
    (match receipt.transition with
     | Keeper_event_queue_state.Transfer_accepted transfer
       when Int64.equal transfer.source_revision expected_revision
            && String.equal transfer.from_keeper keeper_name
            && String.equal transfer.to_keeper target_keeper ->
       Ok (Some { transfer; applied_at = receipt.applied_at })
     | Keeper_event_queue_state.Cancel_accepted _
     | Keeper_event_queue_state.Transfer_accepted _
     | Keeper_event_queue_state.Ack_source_terminal _ ->
       Error
         ("event queue operator operation ID conflicts with transfer request: "
          ^ operator_operation_id))
;;

let fresh_transfer_for_request
      ~queue_state
      ~keeper_name
      ~owner_nonce
      ~expected_revision
      ~queue_index
      ~operator_operation_id
      ~target_keeper
  =
  let* source =
    resolve_pending_source
      ~queue_state
      ~expected_revision
      ~queue_index
  in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source
    ; source_revision = expected_revision
    ; owner_nonce
    ; operator_operation_id
    ; from_keeper = keeper_name
    ; to_keeper = target_keeper
    }
  in
  Ok { transfer; applied_at = Time_compat.now () }
;;

let execute_cancellation ~base_path ~keeper_name prepared =
  let cancellation = prepared.cancellation in
  Keeper_registry_event_queue.cancel_pending_accepted_result
    ~base_path
    keeper_name
    ~current_owner_nonce:cancellation.owner_nonce
    ~applied_at:prepared.applied_at
    ~cancellation
  |> Result.map (fun result ->
    cancellation.source, transition_result_json result)
;;

let target_projection_failure_json source_result detail =
  let receipt = transition_receipt source_result in
  `Assoc
    [ "status", `String "committed_followup_failed"
    ; "transition_id", `String receipt.transition_id
    ; "stage", `String "target_projection"
    ; "detail", `String detail
    ]
;;

let execute_transfer ~base_path ~keeper_name prepared =
  let transfer = prepared.transfer in
  let* source_result =
    Keeper_registry_event_queue.transfer_pending_accepted_result
      ~base_path
      keeper_name
      ~current_owner_nonce:transfer.owner_nonce
      ~applied_at:prepared.applied_at
      ~transfer
  in
  match source_result with
  | Keeper_registry_event_queue.Transition_committed_followup_failed _ ->
    Ok (transfer.source, transition_result_json source_result)
  | Keeper_registry_event_queue.Transition_applied _
  | Keeper_registry_event_queue.Transition_already_applied _ ->
    (match
       Keeper_registry_event_queue.project_accepted_transfer_durable_result
         ~base_path
         transfer.to_keeper
         ~transfer
     with
     | Keeper_registry_event_queue.Stimulus_enqueued
     | Keeper_registry_event_queue.Stimulus_already_present ->
       ignore
         (Keeper_registry.wakeup_running
            ~intent:Keeper_registry.Broadcast_signal
            ~base_path
            transfer.to_keeper :
            Keeper_registry.wakeup_outcome);
       Ok (transfer.source, transition_result_json source_result)
     | Keeper_registry_event_queue.Stimulus_storage_error detail ->
       Ok
         ( transfer.source
         , target_projection_failure_json source_result detail ))
;;

let execute_reprioritization
      ~base_path
      ~keeper_name
      ~queue_state
      ~expected_revision
      ~queue_index
      ~urgency
  =
  let* source =
    resolve_pending_source
      ~queue_state
      ~expected_revision
      ~queue_index
  in
  let* revision =
    Keeper_registry_event_queue.reprioritize_pending_result
      ~base_path
      keeper_name
      ~expected_revision
      ~source
      ~urgency
  in
  ignore
    (Keeper_registry.wakeup_running
       ~intent:Keeper_registry.Broadcast_signal
       ~base_path
       keeper_name :
       Keeper_registry.wakeup_outcome);
  Ok
    ( source
    , `Assoc
        [ "status", `String "applied"
        ; "revision", `String (Int64.to_string revision)
        ] )
;;

let validate_fresh_transfer_target config target_keeper =
  match Keeper_meta_store.read_meta config target_keeper with
  | Error detail ->
    Error ("target keeper metadata is unavailable: " ^ detail)
  | Ok (Some _) -> Ok ()
  | Ok None ->
    let configured =
      Keeper_meta_store.configured_keeper_names config
      |> List.exists (String.equal target_keeper)
    in
    if configured
    then Ok ()
    else Error ("target keeper does not exist: " ^ target_keeper)
;;

let replay_committed_request ~base_path ~keeper_name request =
  match request with
  | Reprioritize _ -> Ok None
  | Cancel
      { expected_revision
      ; queue_index = _
      ; operator_operation_id
      ; reason
      } ->
    let* queue_state =
      Keeper_event_queue_persistence.load_state_result
        ~base_path
        ~keeper_name
    in
    let* prepared =
      prior_cancellation_for_request
        ~queue_state
        ~expected_revision
        ~operator_operation_id
        ~reason
    in
    (match prepared with
     | None -> Ok None
     | Some prepared ->
       execute_cancellation ~base_path ~keeper_name prepared
       |> Result.map Option.some)
  | Transfer
      { expected_revision
      ; queue_index = _
      ; operator_operation_id
      ; target_keeper
      } ->
    let* queue_state =
      Keeper_event_queue_persistence.load_state_result
        ~base_path
        ~keeper_name
    in
    let* prepared =
      prior_transfer_for_request
        ~queue_state
        ~keeper_name
        ~expected_revision
        ~operator_operation_id
        ~target_keeper
    in
    (match prepared with
     | None -> Ok None
     | Some prepared ->
       execute_transfer ~base_path ~keeper_name prepared
       |> Result.map Option.some)
;;

let run_admitted_request
      ~config
      ~base_path
      ~keeper_name
      ~owner_nonce
      request
  =
  let* queue_state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name
  in
  match request with
  | Cancel
      { expected_revision
      ; queue_index
      ; operator_operation_id
      ; reason
      } ->
    let* prior =
      prior_cancellation_for_request
        ~queue_state
        ~expected_revision
        ~operator_operation_id
        ~reason
    in
    let* prepared =
      match prior with
      | Some prepared -> Ok prepared
      | None ->
        fresh_cancellation_for_request
          ~queue_state
          ~owner_nonce
          ~expected_revision
          ~queue_index
          ~operator_operation_id
          ~reason
    in
    execute_cancellation ~base_path ~keeper_name prepared
  | Transfer
      { expected_revision
      ; queue_index
      ; operator_operation_id
      ; target_keeper
      } ->
    if String.equal keeper_name target_keeper
    then Error "source and target keeper must differ"
    else
      let* prior =
        prior_transfer_for_request
          ~queue_state
          ~keeper_name
          ~expected_revision
          ~operator_operation_id
          ~target_keeper
      in
      let* prepared =
        match prior with
        | Some prepared -> Ok prepared
        | None ->
          let* () = validate_fresh_transfer_target config target_keeper in
          fresh_transfer_for_request
            ~queue_state
            ~keeper_name
            ~owner_nonce
            ~expected_revision
            ~queue_index
            ~operator_operation_id
            ~target_keeper
      in
      execute_transfer ~base_path ~keeper_name prepared
  | Reprioritize { expected_revision; queue_index; urgency } ->
    execute_reprioritization
      ~base_path
      ~keeper_name
      ~queue_state
      ~expected_revision
      ~queue_index
      ~urgency
;;

let run_fresh_request ~config ~base_path ~keeper_name request =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Error "keeper is not registered"
  | Some entry ->
    let owner_nonce = entry.meta.runtime.nonce in
    (match
       Keeper_turn_admission.run_if_free ~base_path ~keeper_name (fun () ->
         match Keeper_registry.get ~base_path keeper_name with
         | None -> Error "keeper registration disappeared"
         | Some current when current.meta.runtime.nonce <> owner_nonce ->
           Error "keeper owner nonce changed"
         | Some _ ->
           run_admitted_request
             ~config
             ~base_path
             ~keeper_name
             ~owner_nonce
             request)
     with
     | `Ran result -> result
     | `Busy block ->
       Error
         ("keeper turn is busy: "
          ^ Keeper_turn_admission.autonomous_block_to_string block))
;;

let run ~config ~keeper_name request =
  let base_path = config.Workspace.base_path in
  let* replay =
    replay_committed_request ~base_path ~keeper_name request
  in
  match replay with
  | Some result -> Ok result
  | None ->
    (match run_fresh_request ~config ~base_path ~keeper_name request with
     | Ok _ as result -> result
     | Error original_error ->
       let* replay =
         replay_committed_request ~base_path ~keeper_name request
       in
       (match replay with
        | Some result -> Ok result
        | None -> Error original_error))
;;
