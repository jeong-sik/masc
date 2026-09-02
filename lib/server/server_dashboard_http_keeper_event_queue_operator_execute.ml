let ( let* ) = Result.bind

type request =
  | Cancel of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { source_ref : string
      ; source_incarnation : int64
      ; urgency : Keeper_event_queue.urgency
      }

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

type cancellation_replay =
  | Cancellation_current of prepared_cancellation
  | Cancellation_projected of Keeper_event_queue_state.projected_disposition_witness

type transfer_replay =
  | Transfer_current of prepared_transfer
  | Transfer_projected of Keeper_event_queue_state.projected_disposition_witness

type audit_source =
  { post_id : string
  ; payload_kind : string
  }

let audit_source_of_stimulus source =
  { post_id = source.Keeper_event_queue.post_id
  ; payload_kind = Keeper_event_queue.payload_kind_label source.payload
  }
;;

let audit_source_of_witness witness =
  { post_id = witness.Keeper_event_queue_state.post_id
  ; payload_kind =
      Keeper_event_queue_state.projected_source_kind_to_string
        witness.source_kind
  }
;;

let projected_result_json witness =
  `Assoc
    [ "status", `String "already_applied"
    ; "transition_id", `String witness.Keeper_event_queue_state.transition_id
    ]
;;

let prior_cancellation_for_request
      ~queue_state
      ~source_ref
      ~source_incarnation
      ~operator_operation_id
      ~reason
  =
  match
    Keeper_event_queue_state.prior_disposition_by_operation_id
      operator_operation_id
      queue_state
  with
  | None -> Ok None
  | Some (Keeper_event_queue_state.Current_receipt receipt) ->
    (match receipt.transition with
     | Keeper_event_queue_state.Cancel_accepted cancellation
       when Int64.equal cancellation.source_incarnation source_incarnation
            && String.equal
                 (Keeper_event_queue_state.source_snapshot_ref
                    cancellation.source)
                 source_ref
            && String.equal cancellation.reason reason ->
       Ok (Some (Cancellation_current { cancellation; applied_at = receipt.applied_at }))
     | Keeper_event_queue_state.Cancel_accepted _
     | Keeper_event_queue_state.Transfer_accepted _
     | Keeper_event_queue_state.Ack_source_terminal _ ->
       Error
         ("event queue operator operation ID conflicts with cancellation request: "
          ^ operator_operation_id))
  | Some (Keeper_event_queue_state.Projected_witness witness) ->
    (match witness.kind with
     | Keeper_event_queue_state.Projected_cancel { reason_ref }
       when Int64.equal witness.source_incarnation source_incarnation
            && String.equal witness.source_ref source_ref
            && String.equal
                 reason_ref
                 (Keeper_event_queue_state.disposition_reason_ref reason) ->
       Ok (Some (Cancellation_projected witness))
     | Keeper_event_queue_state.Projected_cancel _
     | Keeper_event_queue_state.Projected_transfer _
     | Keeper_event_queue_state.Projected_fusion_terminal
     | Keeper_event_queue_state.Projected_hitl_terminal
     | Keeper_event_queue_state.Projected_turn_completed
     | Keeper_event_queue_state.Projected_turn_attempt_terminal ->
       Error
         ("event queue operator operation ID conflicts with cancellation request: "
          ^ operator_operation_id))
;;

let fresh_cancellation_for_request
      ~queue_state
      ~source_ref
      ~source_incarnation
      ~operator_operation_id
      ~reason
  =
  let* selection =
    Keeper_event_queue_state.resolve_pending_selection
      ~source_ref
      ~source_incarnation
      queue_state
  in
  let cancellation : Keeper_registry_event_queue.accepted_cancellation =
    { source = selection.source
    ; source_incarnation
    ; operator_operation_id
    ; reason
    }
  in
  Ok { cancellation; applied_at = Time_compat.now () }
;;

let prior_transfer_for_request
      ~queue_state
      ~keeper_name
      ~source_ref
      ~source_incarnation
      ~operator_operation_id
      ~target_keeper
  =
  match
    Keeper_event_queue_state.prior_disposition_by_operation_id
      operator_operation_id
      queue_state
  with
  | None -> Ok None
  | Some (Keeper_event_queue_state.Current_receipt receipt) ->
    (match receipt.transition with
     | Keeper_event_queue_state.Transfer_accepted transfer
       when Int64.equal transfer.source_incarnation source_incarnation
            && String.equal
                 (Keeper_event_queue_state.source_snapshot_ref
                    transfer.source)
                 source_ref
            && String.equal transfer.from_keeper keeper_name
            && String.equal transfer.to_keeper target_keeper ->
       Ok (Some (Transfer_current { transfer; applied_at = receipt.applied_at }))
     | Keeper_event_queue_state.Cancel_accepted _
     | Keeper_event_queue_state.Transfer_accepted _
     | Keeper_event_queue_state.Ack_source_terminal _ ->
       Error
         ("event queue operator operation ID conflicts with transfer request: "
          ^ operator_operation_id))
  | Some (Keeper_event_queue_state.Projected_witness witness) ->
    (match witness.kind with
     | Keeper_event_queue_state.Projected_transfer
         { from_keeper; to_keeper; _ }
       when Int64.equal witness.source_incarnation source_incarnation
            && String.equal witness.source_ref source_ref
            && String.equal from_keeper keeper_name
            && String.equal to_keeper target_keeper ->
       Ok (Some (Transfer_projected witness))
     | Keeper_event_queue_state.Projected_cancel _
     | Keeper_event_queue_state.Projected_transfer _
     | Keeper_event_queue_state.Projected_fusion_terminal
     | Keeper_event_queue_state.Projected_hitl_terminal
     | Keeper_event_queue_state.Projected_turn_completed
     | Keeper_event_queue_state.Projected_turn_attempt_terminal ->
       Error
         ("event queue operator operation ID conflicts with transfer request: "
          ^ operator_operation_id))
;;

let fresh_transfer_for_request
      ~queue_state
      ~keeper_name
      ~source_ref
      ~source_incarnation
      ~operator_operation_id
      ~target_keeper
      ~(target_meta : Keeper_meta_contract.keeper_meta)
  =
  let* selection =
    Keeper_event_queue_state.resolve_pending_selection
      ~source_ref
      ~source_incarnation
      queue_state
  in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation
    ; operator_operation_id
    ; from_keeper = keeper_name
    ; to_keeper = target_keeper
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  Ok { transfer; applied_at = Time_compat.now () }
;;

let execute_cancellation ~base_path ~keeper_name prepared =
  let cancellation = prepared.cancellation in
  Keeper_registry_event_queue.cancel_pending_accepted_result
    ~base_path
    keeper_name
    ~applied_at:prepared.applied_at
    ~cancellation
  |> Result.map (fun result ->
    Some (audit_source_of_stimulus cancellation.source), transition_result_json result)
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
  let execute_fenced ~source_intake_token ~target_intake_token =
    let* source_result =
      Keeper_registry_event_queue.transfer_pending_accepted_result
        ~intake_token:source_intake_token
        ~base_path
        keeper_name
        ~applied_at:prepared.applied_at
        ~transfer
      |> Result.map_error Keeper_registry_event_queue.transfer_pending_error_to_string
    in
    match source_result with
    | Keeper_registry_event_queue.Transition_committed_followup_failed _ ->
      Ok (Some (audit_source_of_stimulus transfer.source), transition_result_json source_result)
    | Keeper_registry_event_queue.Transition_applied _
    | Keeper_registry_event_queue.Transition_already_applied _ ->
      (match
         Keeper_registry_event_queue.project_accepted_transfer_durable_result
           ~intake_token:target_intake_token
           ~base_path
           transfer.to_keeper
           ~transfer
       with
       | Keeper_registry_event_queue.Transfer_projection_committed
       | Keeper_registry_event_queue.Transfer_projection_already_committed ->
         ignore
           (Keeper_registry.wakeup_running
              ~intent:Keeper_registry.Broadcast_signal
              ~base_path
              transfer.to_keeper :
              Keeper_registry.wakeup_outcome);
         Ok (Some (audit_source_of_stimulus transfer.source), transition_result_json source_result)
       | Keeper_registry_event_queue.Transfer_projection_storage_error detail ->
         Ok
           ( Some (audit_source_of_stimulus transfer.source)
           , target_projection_failure_json source_result detail )
       | Keeper_registry_event_queue.Transfer_projection_target_unavailable error ->
         Ok
           ( Some (audit_source_of_stimulus transfer.source)
           , target_projection_failure_json
               source_result
               (Keeper_registry_event_queue.transfer_target_error_to_string error) )
       | Keeper_registry_event_queue.Transfer_projection_shutdown_reserved operation_id ->
         let detail =
           Printf.sprintf
             "target Keeper shutdown owns durable intake operation=%s"
             (Keeper_shutdown_types.Operation_id.to_string operation_id)
         in
         Ok
           ( Some (audit_source_of_stimulus transfer.source)
           , target_projection_failure_json source_result detail ))
  in
  match
    Keeper_shutdown_intake_fence.run_transfer_intake_if_open
      ~base_path
      ~from_keeper:keeper_name
      ~to_keeper:transfer.to_keeper
      execute_fenced
  with
  | Keeper_shutdown_intake_fence.Transfer_intake_committed result -> result
  | Keeper_shutdown_intake_fence.Transfer_intake_source_shutdown_reserved operation_id ->
    Error
      (Keeper_registry_event_queue.transfer_pending_error_to_string
         (Keeper_registry_event_queue.Transfer_pending_shutdown_reserved operation_id))
  | Keeper_shutdown_intake_fence.Transfer_intake_target_shutdown_reserved operation_id ->
    Error
      (Printf.sprintf
         "target Keeper shutdown owns durable intake operation=%s"
         (Keeper_shutdown_types.Operation_id.to_string operation_id))
;;

let execute_reprioritization
      ~base_path
      ~keeper_name
      ~queue_state
      ~source_ref
      ~source_incarnation
      ~urgency
  =
  let* selection =
    Keeper_event_queue_state.resolve_pending_selection
      ~source_ref
      ~source_incarnation
      queue_state
  in
  let* revision =
    Keeper_registry_event_queue.reprioritize_pending_result
      ~base_path
      keeper_name
      ~selection
      ~urgency
  in
  ignore
    (Keeper_registry.wakeup_running
       ~intent:Keeper_registry.Broadcast_signal
       ~base_path
       keeper_name :
       Keeper_registry.wakeup_outcome);
  Ok
    ( Some (audit_source_of_stimulus selection.source)
    , `Assoc
        [ "status", `String "applied"
        ; "revision", `String (Int64.to_string revision)
        ] )
;;

let validate_fresh_transfer_target config target_keeper =
  match Keeper_meta_store.read_meta config target_keeper with
  | Error detail ->
    Error ("target keeper metadata is unavailable: " ^ detail)
  | Ok (Some meta) -> Ok meta
  | Ok None -> Error ("target keeper does not exist: " ^ target_keeper)
;;

let replay_committed_request ~base_path ~keeper_name request =
  match request with
  | Reprioritize _ -> Ok None
  | Cancel
      { source_ref
      ; source_incarnation
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
        ~source_ref
        ~source_incarnation
        ~operator_operation_id
        ~reason
    in
    (match prepared with
     | None -> Ok None
     | Some (Cancellation_projected witness) ->
       Ok (Some (Some (audit_source_of_witness witness), projected_result_json witness))
     | Some (Cancellation_current prepared) ->
       execute_cancellation ~base_path ~keeper_name prepared
       |> Result.map Option.some)
  | Transfer
      { source_ref
      ; source_incarnation
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
        ~source_ref
        ~source_incarnation
        ~operator_operation_id
        ~target_keeper
    in
    (match prepared with
     | None -> Ok None
     | Some (Transfer_projected witness) ->
       Ok (Some (Some (audit_source_of_witness witness), projected_result_json witness))
     | Some (Transfer_current prepared) ->
       execute_transfer ~base_path ~keeper_name prepared
       |> Result.map Option.some)
;;

let run_admitted_request
      ~config
      ~base_path
      ~keeper_name
      request
  =
  let* queue_state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path
      ~keeper_name
  in
  match request with
  | Cancel
      { source_ref
      ; source_incarnation
      ; operator_operation_id
      ; reason
      } ->
    let* prior =
      prior_cancellation_for_request
        ~queue_state
        ~source_ref
        ~source_incarnation
        ~operator_operation_id
        ~reason
    in
    let* prepared =
      match prior with
      | Some replay -> Ok replay
      | None ->
        fresh_cancellation_for_request
          ~queue_state
          ~source_ref
          ~source_incarnation
          ~operator_operation_id
          ~reason
        |> Result.map (fun prepared -> Cancellation_current prepared)
    in
    (match prepared with
     | Cancellation_projected witness ->
       Ok (Some (audit_source_of_witness witness), projected_result_json witness)
     | Cancellation_current prepared ->
       execute_cancellation ~base_path ~keeper_name prepared)
  | Transfer
      { source_ref
      ; source_incarnation
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
          ~source_ref
          ~source_incarnation
          ~operator_operation_id
          ~target_keeper
      in
      let* prepared =
        match prior with
        | Some replay -> Ok replay
        | None ->
          let* target_meta = validate_fresh_transfer_target config target_keeper in
          fresh_transfer_for_request
            ~queue_state
            ~keeper_name
            ~source_ref
            ~source_incarnation
            ~operator_operation_id
            ~target_keeper
            ~target_meta
          |> Result.map (fun prepared -> Transfer_current prepared)
      in
      (match prepared with
       | Transfer_projected witness ->
         Ok (Some (audit_source_of_witness witness), projected_result_json witness)
       | Transfer_current prepared ->
         execute_transfer ~base_path ~keeper_name prepared)
  | Reprioritize { source_ref; source_incarnation; urgency } ->
    execute_reprioritization
      ~base_path
      ~keeper_name
      ~queue_state
      ~source_ref
      ~source_incarnation
      ~urgency
;;

let run_fresh_request ~config ~base_path ~keeper_name request =
  match Keeper_registry.get ~base_path keeper_name with
  | None ->
    (match request with
     | Transfer _ | Reprioritize _ -> Error "keeper is not registered"
     | Cancel _ ->
       (* Cancellation is the recovery path for a queue whose owner was
          intentionally removed.  Reserve the lifecycle key before proving
          that both live and durable owner identities are absent; registration
          and Keeper creation use the same reservation boundary, so no owner
          can appear between admission and the durable transition commit. *)
       (match
          Keeper_lifecycle_reservation.acquire
            ~base_path
            ~keeper_name
            ~purpose:Keeper_lifecycle_reservation.Paused_work_disposition
        with
        | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
          Error
            ("keeper lifecycle is reserved: "
             ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
        | Ok token ->
          let release () =
            match Keeper_lifecycle_reservation.release token with
            | Keeper_lifecycle_reservation.Released -> ()
            | ( Keeper_lifecycle_reservation.Release_missing
              | Keeper_lifecycle_reservation.Release_not_owner _ ) as outcome ->
              Log.Keeper.error
                "orphan event cancellation reservation release failed keeper=%s outcome=%s"
                keeper_name
                (Keeper_lifecycle_reservation.release_outcome_to_string outcome)
          in
          Fun.protect
            ~finally:(fun () -> Eio.Cancel.protect release)
            (fun () ->
               match Keeper_registry.get ~base_path keeper_name with
               | Some _ -> Error "keeper registered during orphan cancellation admission"
               | None ->
                 (match Keeper_meta_store.read_meta config keeper_name with
                  | Error detail ->
                    Error ("keeper metadata is unavailable: " ^ detail)
                  | Ok (Some _) ->
                    Error
                      "keeper metadata exists; boot or resume the owner before cancelling events"
                  | Ok None ->
                    run_admitted_request
                      ~config
                      ~base_path
                      ~keeper_name
                      request))))
  | Some _ ->
    (match
       Keeper_owner_registry.run_maintenance_if_idle
         ~base_path
         ~keeper_name
         (fun () ->
            match Keeper_registry.get ~base_path keeper_name with
            | None -> Error "keeper registration disappeared"
            | Some _ ->
              run_admitted_request
                ~config
                ~base_path
                ~keeper_name
                request)
     with
     | Ok (`Ran result) -> result
     | Ok (`Busy block) ->
       Error ("keeper owner is busy: " ^ Keeper_owner.autonomous_block_to_string block)
     | Error error ->
       Error
         ("keeper owner unavailable: "
          ^ Keeper_owner_registry.command_error_to_string error))
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
