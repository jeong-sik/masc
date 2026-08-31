(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t].  The durable v2 envelope is
    the mutation authority; these wrappers publish its pending projection to
    that per-entry Atomic only after commit.  No coupling to the central
    registry Atomic state primitive. *)

let publish_pending ~base_path name pending =
  (match Keeper_registry.get ~base_path name with
   | None -> ()
   | Some entry -> Atomic.set entry.event_queue pending);
  Keeper_waiting_inventory_broadcast.changed
    ~keeper_name:name
    ~source:Event_queue
;;

type accepted_cancellation = Keeper_event_queue_persistence.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_persistence.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt = Keeper_event_queue_persistence.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal = Keeper_event_queue_persistence.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition = Keeper_event_queue_persistence.transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt = Keeper_event_queue_persistence.transition_receipt
type outbox_entry = Keeper_event_queue_persistence.outbox_entry

type transition_result = Keeper_event_queue_persistence.transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt
  | Transition_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type transfer_pending_error =
  | Transfer_pending_storage_error of string
  | Transfer_pending_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

let transfer_pending_error_to_string = function
  | Transfer_pending_storage_error detail -> detail
  | Transfer_pending_shutdown_reserved operation_id ->
    Printf.sprintf
      "source Keeper shutdown owns durable transfer intake operation=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
;;

type source_ack_result =
  | Acked of transition_receipt
  | Already_acked of transition_receipt
  | Ack_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

(* A source has not settled while its exact reaction evidence is still waiting
   in the transition outbox: the next terminal ACK is deliberately rejected in
   that state. Complete the existing handoff on the owner-facing path instead
   of making the next Keeper turn wait for the maintenance sweep. *)
let project_source_ack_receipt ~base_path ~keeper_name receipt success =
  match
    Keeper_reaction_ledger.project_event_queue_transition_outbox_result
      ~base_path
      ~keeper_name
      ~expected_transition_id:
        receipt.Keeper_event_queue_state.transition_id
  with
  | Ok () -> Ok (success receipt)
  | Error detail ->
    Ok
      (Ack_committed_followup_failed
         { receipt; stage = `Projection; detail })
;;

let project_source_ack_result ~base_path ~keeper_name result =
  match result with
  | Error _ as error -> error
  | Ok (Transition_applied receipt) ->
    project_source_ack_receipt
      ~base_path
      ~keeper_name
      receipt
      (fun receipt -> Acked receipt)
  | Ok (Transition_already_applied receipt) ->
    project_source_ack_receipt
      ~base_path
      ~keeper_name
      receipt
      (fun receipt -> Already_acked receipt)
  | Ok (Transition_committed_followup_failed { receipt; stage; detail }) ->
    Ok (Ack_committed_followup_failed { receipt; stage; detail })
;;

let enqueue_if_missing queue stimulus =
  if Keeper_event_queue.contains queue stimulus
  then queue
  else Keeper_event_queue.enqueue queue stimulus
;;

let rec stimulus_with_post_id queue post_id =
  match Keeper_event_queue.dequeue queue with
  | None -> None
  | Some (stimulus, rest) ->
    if String.equal stimulus.post_id post_id
    then Some stimulus
    else stimulus_with_post_id rest post_id
;;

let enqueue_external_decision queue stimulus =
  match stimulus_with_post_id queue stimulus.Keeper_event_queue.post_id with
  | None -> Ok (Keeper_event_queue.enqueue queue stimulus)
  | Some committed
    when Keeper_event_queue.stimulus_identity_equal committed stimulus ->
    Ok queue
  | Some _ ->
    Error
      (Printf.sprintf
         "conflicting durable stimulus already exists for post_id=%s"
         stimulus.post_id)
;;

type durable_intake_error =
  | Durable_intake_token_not_live
  | Durable_intake_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

let durable_intake_error_to_string = function
  | Durable_intake_token_not_live ->
    "durable intake token is not live for this Keeper"
  | Durable_intake_shutdown_reserved operation_id ->
    Printf.sprintf
      "keeper durable intake rejected by shutdown operation=%s"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
;;

let with_durable_intake
      ?intake_token
      ~base_path
      ~keeper_name
      operation
  =
  match intake_token with
  | Some token ->
    if
      Keeper_shutdown_intake_fence.intake_token_matches
        token
        ~base_path
        ~keeper_name
    then Ok (operation ())
    else Error Durable_intake_token_not_live
  | None ->
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path
         ~keeper_name
         (fun _intake_token -> Ok (operation ()))
     with
     | Keeper_shutdown_intake_fence.Intake_committed result -> result
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
       Error (Durable_intake_shutdown_reserved operation_id))
;;

let enqueue_unfenced ~base_path name stimulus =
  if Option.is_none (Keeper_registry.get ~base_path name)
  then
    Log.Keeper.warn
      "registry: enqueue_event name=%s base_path=%s: keeper not registered; persisting stimulus for replay"
      name
      base_path;
  let committed_pending = ref None in
  match
    Keeper_event_queue_persistence.update_checked_result
      ~base_path
      ~keeper_name:name
      ~after_commit:(fun () ->
        match !committed_pending with
        | None -> ()
        | Some pending -> publish_pending ~base_path name pending)
      (fun current ->
         let pending = enqueue_if_missing current stimulus in
         committed_pending := Some pending;
         Ok pending)
  with
  | Ok () -> Ok ()
  | Error message -> Error message
;;

let enqueue ?intake_token ~base_path name stimulus =
  match
    with_durable_intake
      ?intake_token
      ~base_path
      ~keeper_name:name
      (fun () -> enqueue_unfenced ~base_path name stimulus)
  with
  | Ok (Ok ()) -> ()
  | Ok (Error message) ->
    Log.Keeper.error
      "registry: durable enqueue failed name=%s base_path=%s post_id=%s: %s"
      name
      base_path
      stimulus.Keeper_event_queue.post_id
      message
  | Error error ->
    Log.Keeper.error
      "registry: durable enqueue failed name=%s base_path=%s post_id=%s: %s"
      name
      base_path
      stimulus.Keeper_event_queue.post_id
      (durable_intake_error_to_string error)
;;

let enqueue_durable_result_unfenced ~base_path name stimulus =
  (* Commit the identity-deduplicated durable row before exposing a successful
     delivery result. This path is intentionally separate from [enqueue]: most
     stimuli already have an upstream replay source, while HITL resolution is
     the sole carrier of an operator decision and must fail closed. *)
  let committed_pending = ref None in
  Keeper_event_queue_persistence.update_checked_result
    ~base_path
    ~keeper_name:name
    ~after_commit:(fun () ->
      match !committed_pending with
      | None -> ()
      | Some pending -> publish_pending ~base_path name pending)
    (fun queue ->
       match enqueue_external_decision queue stimulus with
       | Error _ as error -> error
       | Ok pending ->
         committed_pending := Some pending;
         Ok pending)
;;

let enqueue_durable_result ?intake_token ~base_path name stimulus =
  match
    with_durable_intake
      ?intake_token
      ~base_path
      ~keeper_name:name
      (fun () -> enqueue_durable_result_unfenced ~base_path name stimulus)
  with
  | Ok result -> result
  | Error error -> Error (durable_intake_error_to_string error)
;;

type enqueue_if_missing_durable_result =
  | Enqueued
  | Already_present
  | Identity_conflict of string
  | Storage_error of string

let board_attention_event_id (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_attention attention -> Some attention.candidate_id
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Ask_answered _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  | Keeper_event_queue.Delegate_completed _
  | Keeper_event_queue.Composition_completed _ ->
    None
;;

let stimulus_with_board_attention_event_id queue event_id =
  let rec loop = function
    | [] -> None
    | stimulus :: rest ->
      (match board_attention_event_id stimulus with
       | Some candidate_id when String.equal candidate_id event_id -> Some stimulus
       | Some _ | None -> loop rest)
  in
  loop (Keeper_event_queue.to_list queue)
;;

let enqueue_if_missing_durable_result_unfenced ~base_path ~event_id name stimulus =
  match board_attention_event_id stimulus with
  | None ->
    Identity_conflict
      "opaque durable event identity requires a Board_attention payload"
  | Some payload_event_id when not (String.equal payload_event_id event_id) ->
    Identity_conflict
      (Printf.sprintf
         "durable event identity mismatch: argument=%S payload=%S"
         event_id
         payload_event_id)
  | Some _ when String.equal event_id "" ->
    Identity_conflict "durable event identity must not be empty"
  | Some _ ->
    let committed_pending = ref None in
    let commit_result = ref Enqueued in
    let identity_conflict = ref None in
    (match
       Keeper_event_queue_persistence.update_checked_result
         ~base_path
         ~keeper_name:name
         ~after_commit:(fun () ->
           match !committed_pending with
           | None -> ()
           | Some pending -> publish_pending ~base_path name pending)
         (fun queue ->
            match stimulus_with_board_attention_event_id queue event_id with
            | None ->
              let pending = Keeper_event_queue.enqueue queue stimulus in
              committed_pending := Some pending;
              commit_result := Enqueued;
              Ok pending
            | Some existing
              when Keeper_event_queue.stimulus_identity_equal existing stimulus ->
              committed_pending := Some queue;
              commit_result := Already_present;
              Ok queue
            | Some _ ->
              let detail =
                Printf.sprintf
                  "conflicting durable Board-attention event for event_id=%s"
                  event_id
              in
              identity_conflict := Some detail;
              Error detail)
     with
     | Ok () -> !commit_result
     | Error detail ->
       (match !identity_conflict with
        | Some conflict -> Identity_conflict conflict
        | None -> Storage_error detail))
;;

let enqueue_if_missing_durable_result
      ?intake_token
      ~base_path
      ~event_id
      name
      stimulus
  =
  match
    with_durable_intake
      ?intake_token
      ~base_path
      ~keeper_name:name
      (fun () ->
         enqueue_if_missing_durable_result_unfenced
           ~base_path
           ~event_id
           name
           stimulus)
  with
  | Ok result -> result
  | Error error -> Storage_error (durable_intake_error_to_string error)
;;

type enqueue_stimulus_durable_result =
  | Stimulus_enqueued
  | Stimulus_already_present
  | Stimulus_storage_error of string

type transfer_target_error =
  | Transfer_target_name_mismatch of
      { expected : string
      ; actual : string
      }
  | Transfer_target_metadata_read_failed of string
  | Transfer_target_metadata_absent
  | Transfer_target_trace_changed

let transfer_target_error_to_string = function
  | Transfer_target_name_mismatch { expected; actual } ->
    Printf.sprintf
      "transfer target Keeper mismatch: expected=%s actual=%s"
      expected
      actual
  | Transfer_target_metadata_read_failed detail ->
    "target Keeper metadata read failed: " ^ detail
  | Transfer_target_metadata_absent -> "target Keeper metadata is absent"
  | Transfer_target_trace_changed -> "target Keeper trace identity changed"
;;

type transfer_projection_result =
  | Transfer_projection_committed
  | Transfer_projection_already_committed
  | Transfer_projection_storage_error of string
  | Transfer_projection_target_unavailable of transfer_target_error
  | Transfer_projection_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

let enqueue_stimulus_durable_result_unfenced ~base_path name stimulus =
  match
    Keeper_event_queue_persistence.enqueue_stimulus_if_absent_result
      ~base_path
      ~keeper_name:name
      ~after_commit:(publish_pending ~base_path name)
      stimulus
  with
  | Ok Keeper_event_queue_persistence.Enqueued -> Stimulus_enqueued
  | Ok Keeper_event_queue_persistence.Already_present -> Stimulus_already_present
  | Error detail -> Stimulus_storage_error detail
;;

let enqueue_stimulus_durable_result
      ?intake_token
      ~base_path
      name
      stimulus
  =
  match
    with_durable_intake
      ?intake_token
      ~base_path
      ~keeper_name:name
      (fun () -> enqueue_stimulus_durable_result_unfenced ~base_path name stimulus)
  with
  | Ok result -> result
  | Error error -> Stimulus_storage_error (durable_intake_error_to_string error)
;;

let project_accepted_transfer_durable_result
      ?intake_token
      ~base_path
      name
      ~transfer
  =
  let validate_target_identity () =
    let config = Workspace.default_config base_path in
    if not (String.equal name transfer.to_keeper)
    then
      Error
        (Transfer_target_name_mismatch
           { expected = transfer.to_keeper; actual = name })
    else
      match Keeper_meta_store.read_meta config name with
    | Error detail -> Error (Transfer_target_metadata_read_failed detail)
    | Ok None -> Error Transfer_target_metadata_absent
    | Ok (Some meta)
      when not (Keeper_id.Trace_id.equal meta.runtime.trace_id transfer.target_trace_id) ->
      Error Transfer_target_trace_changed
    | Ok (Some _) -> Ok ()
  in
  let project () =
    Keeper_event_queue_persistence.project_accepted_transfer_guarded_result
      ~authorize_first_projection:validate_target_identity
      ~base_path
      ~keeper_name:name
      ~after_commit:(publish_pending ~base_path name)
      ~transfer
  in
  let interpret = function
  | Ok (Keeper_event_queue_persistence.First_projection_rejected detail) ->
    Transfer_projection_target_unavailable detail
  | Ok (Keeper_event_queue_persistence.Transfer_projection_result result) ->
    (match result with
     | Keeper_event_queue_persistence.Transfer_projected ->
       Transfer_projection_committed
     | Keeper_event_queue_persistence.Transfer_already_projected ->
       Transfer_projection_already_committed)
  | Error detail ->
    Transfer_projection_storage_error detail
  in
  match intake_token with
  | Some token ->
    if
      Keeper_shutdown_intake_fence.intake_token_matches
        token
        ~base_path
        ~keeper_name:name
    then interpret (project ())
    else
      Transfer_projection_storage_error
        "target transfer durable intake token is not live for this Keeper"
  | None ->
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path
         ~keeper_name:name
         (fun _intake_token -> project ())
     with
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
       Transfer_projection_shutdown_reserved operation_id
     | Keeper_shutdown_intake_fence.Intake_committed result -> interpret result)
;;

type hitl_resolution_enqueue_error =
  | Hitl_recipient_absent
  | Hitl_enqueue_failed of string

let hitl_resolution_enqueue_error_to_string = function
  | Hitl_recipient_absent ->
    "hitl resolution rejected because the Keeper does not exist"
  | Hitl_enqueue_failed reason -> reason
;;

let enqueue_hitl_resolution_durable_result
    ~base_path
    ~keeper_name
    ~approval_id
    ~decision
    ~channel
  =
  let resolution : Keeper_event_queue.hitl_resolution =
    { approval_id; decision; channel }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Hitl_resolved resolution
    }
  in
  (* This is the sole carrier of an operator decision and must fail closed:
     a resolution addressed to a Keeper that does not exist can never be
     consumed, so it is reported as [Hitl_recipient_absent] before any
     durable row is written. Generic stimuli take no such check — the queue
     stays an open mailbox. A Keeper mid-shutdown is fenced by the intake
     reservation below, which keeps the delivery replayable until the
     removal either completes or unwinds. *)
  match
    Keeper_meta_store.read_meta (Workspace.default_config base_path) keeper_name
  with
  | Error detail -> Error (Hitl_enqueue_failed detail)
  | Ok None -> Error Hitl_recipient_absent
  | Ok (Some _) ->
    (match
       with_durable_intake
         ~base_path
         ~keeper_name
         (fun () ->
           enqueue_durable_result_unfenced ~base_path keeper_name stimulus)
     with
     | Ok (Ok ()) -> Ok ()
     | Ok (Error message) -> Error (Hitl_enqueue_failed message)
     | Error
         (( Durable_intake_token_not_live
          | Durable_intake_shutdown_reserved _ ) as error) ->
       Error (Hitl_enqueue_failed (durable_intake_error_to_string error)))
;;

let drop_by_post_id ~base_path name ~post_id =
  match
    Keeper_event_queue_persistence.drop_by_post_id
      ~base_path
      ~keeper_name:name
      ~post_id
      ~after_commit:(publish_pending ~base_path name)
      ()
  with
  | Error msg ->
    Log.Keeper.warn
      "registry: drop_by_post_id failed name=%s post_id=%s: %s"
      name
      post_id
      msg;
    Error msg
  | Ok persisted_removed -> Ok persisted_removed
;;

let snapshot_result ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Keeper_event_queue_persistence.load_result ~base_path ~keeper_name:name
  | Some entry -> Ok (Atomic.get entry.event_queue)
;;

let durable_state_result ~base_path name =
  Keeper_event_queue_persistence.load_state_result
    ~base_path
    ~keeper_name:name
;;

let reprioritize_pending_result
      ~base_path
      name
      ~selection
      ~urgency
  =
  Keeper_event_queue_persistence.reprioritize_pending_result
    ~base_path
    ~keeper_name:name
    ~selection
    ~urgency
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let defer_pending_result ~base_path name ~selection =
  Keeper_event_queue_persistence.defer_pending_result
    ~base_path
    ~keeper_name:name
    ~selection
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let peek_when_result ~base_path name ~now ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.peek_when_result
      ~base_path
      ~keeper_name:name
      ~now
      ~ready
;;

let select_when_result ~base_path name ~now ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.select_when_result
      ~base_path
      ~keeper_name:name
      ~now
      ~ready
;;

let pending_selections_result ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.pending_selections_result
      ~base_path
      ~keeper_name:name
;;

let validate_pending_selection_result ~base_path name ~selection =
  Keeper_event_queue_persistence.validate_pending_selection_result
    ~base_path
    ~keeper_name:name
    ~selection
;;

let ack_pending_result ~base_path name ~selection =
  Keeper_event_queue_persistence.ack_pending_result
    ~base_path
    ~keeper_name:name
    ~selection
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let cancel_pending_accepted_result
      ~base_path
      name
      ~applied_at
      ~cancellation
  =
  Keeper_event_queue_persistence.cancel_pending_accepted_result
    ~base_path
    ~keeper_name:name
    ~applied_at
    ~cancellation
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let cancel_scheduled_wakes_result ~base_path name ~applied_at ~schedule_ids ~reason =
  (* Cancel propagation (task-370): a cancelled schedule's already-enqueued
     utterances must leave the durable queue at the cancel boundary, not ride
     the wake path of an owner who will never be woken for them again. Each
     removal goes through the exact accepted-cancellation transition, so the
     WAL records it with a distinct operation id and the pending projection
     republishes when the owner lane is live. Reads the durable state through
     persistence directly: a schedule can outlive its keeper's registry
     registration (the purge path cancels exactly such schedules), and the
     queue directory remains the authority for pending stimuli either way. *)
  let schedule_ids = Array.of_list schedule_ids in
  let matching (stimulus : Keeper_event_queue.stimulus) =
    match stimulus.payload with
    | Schedule_due wake ->
      Array.exists
        (fun schedule_id -> String.equal wake.schedule_id schedule_id)
        schedule_ids
    | _ -> false
  in
  match
    Keeper_event_queue_persistence.pending_selections_result
      ~base_path
      ~keeper_name:name
  with
  | Error _ as error -> error
  | Ok selections ->
    let cancelled =
      List.filter_map
        (fun (selection : Keeper_event_queue_state.pending_selection) ->
           if matching selection.source then
             let operation_id =
               Printf.sprintf
                 "schedule-cancel:%s:%s"
                 name
                 (string_of_float (Time_compat.now ()))
             in
             Some
               { Keeper_event_queue_state.source = selection.source
               ; source_incarnation = selection.admitted_revision
               ; operator_operation_id = operation_id
               ; reason
               }
           else None)
        selections
    in
    List.fold_left
      (fun acc cancellation ->
         match acc with
         | Error _ as error -> error
         | Ok count ->
           (match
              Keeper_event_queue_persistence.cancel_pending_accepted_result
                ~base_path
                ~keeper_name:name
                ~applied_at
                ~cancellation
                ()
            with
            | Ok _ -> Ok (count + 1)
            | Error detail -> Error detail))
      (Ok 0)
      cancelled
;;

let drain_owner_absent_pending_result ~base_path name ~applied_at ~reason =
  (* Owner-absent termination (task-370): when the Keeper store holds no
     metadata for a name that owns durable pending work, no maintenance cycle
     can make the wait productive -- the work can never execute until an
     operator registers the name. The observed outcome of retaining it was a
     913-error day for one stale tenant queue and 881 retained visits for
     keeper-taskmaster-agent. Drain the pending entries now, through the same
     exact accepted-cancellation transition, instead of re-visiting them
     every cycle. [pending_selections_result] refuses unregistered names, but
     an owner-absent queue is by definition unregistered, so this reads the
     durable state directly through persistence. *)
  match
    Keeper_event_queue_persistence.pending_selections_result
      ~base_path
      ~keeper_name:name
  with
  | Error _ as error -> error
  | Ok selections ->
    List.fold_left
      (fun acc (selection : Keeper_event_queue_state.pending_selection) ->
         match acc with
         | Error _ as error -> error
         | Ok count ->
           let operation_id =
             Printf.sprintf
               "owner-absent-drain:%s:%s"
               name
               (string_of_float (Time_compat.now ()))
           in
           let cancellation =
             { Keeper_event_queue_state.source = selection.source
             ; source_incarnation = selection.admitted_revision
             ; operator_operation_id = operation_id
             ; reason
             }
           in
           (match
              Keeper_event_queue_persistence.cancel_pending_accepted_result
                ~base_path
                ~keeper_name:name
                ~applied_at
                ~cancellation
                ()
            with
            | Ok _ -> Ok (count + 1)
            | Error detail -> Error detail))
      (Ok 0)
      selections
;;

let transfer_pending_accepted_result
      ?intake_token
      ~base_path
      name
      ~applied_at
      ~transfer
  =
  let commit () =
    Keeper_event_queue_persistence.transfer_pending_accepted_result
      ~base_path
      ~keeper_name:name
      ~applied_at
      ~transfer
      ~after_commit:(publish_pending ~base_path name)
      ()
    |> Result.map_error (fun detail -> Transfer_pending_storage_error detail)
  in
  match intake_token with
  | Some token ->
    if
      Keeper_shutdown_intake_fence.intake_token_matches
        token
        ~base_path
        ~keeper_name:name
    then commit ()
    else
      Error
        (Transfer_pending_storage_error
           "source transfer durable intake token is not live for this Keeper")
  | None ->
    (match
       Keeper_shutdown_intake_fence.run_durable_intake_if_open
         ~base_path
         ~keeper_name:name
         (fun _intake_token -> commit ())
     with
     | Keeper_shutdown_intake_fence.Intake_committed result -> result
     | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
       Error (Transfer_pending_shutdown_reserved operation_id))
;;

let ack_pending_source_terminal_result
      ~base_path
      name
      ~acked_at
      ~source_terminal
  =
  Keeper_event_queue_persistence.ack_pending_source_terminal_result
    ~base_path
    ~keeper_name:name
    ~acked_at
    ~source_terminal
    ~after_commit:(publish_pending ~base_path name)
    ()
  |> project_source_ack_result ~base_path ~keeper_name:name
;;

let terminalize_pending_turn_attempt_result
      ~base_path
      name
      ~applied_at
      ~selection
      ~detail
  =
  Keeper_event_queue_persistence.terminalize_pending_turn_attempt_result
    ~base_path
    ~keeper_name:name
    ~applied_at
    ~selection
    ~detail
    ~after_commit:(publish_pending ~base_path name)
    ()
  |> project_source_ack_result ~base_path ~keeper_name:name
;;

let terminalize_pending_turn_completed_result
      ~base_path
      name
      ~applied_at
      ~selection
  =
  Keeper_event_queue_persistence.terminalize_pending_turn_completed_result
    ~base_path
    ~keeper_name:name
    ~applied_at
    ~selection
    ~after_commit:(publish_pending ~base_path name)
    ()
  |> project_source_ack_result ~base_path ~keeper_name:name
;;
