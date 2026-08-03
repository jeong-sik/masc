(** Per-keeper event-queue access.

    Extracted from keeper_registry.ml (lines 1854-1900) as part of the
    godfile decomp campaign. Each [registry_entry] carries its own
    [event_queue : Keeper_event_queue.t Atomic.t].  The durable v2 envelope is
    the mutation authority; these wrappers publish its pending projection to
    that per-entry Atomic only after commit.  No coupling to the central
    registry Atomic state primitive. *)

let publish_pending ~base_path name pending =
  match Keeper_registry.get ~base_path name with
  | None -> ()
  | Some entry -> Atomic.set entry.event_queue pending
;;

type accepted_cancellation = Keeper_event_queue_persistence.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = Keeper_event_queue_persistence.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt = Keeper_event_queue_persistence.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal = Keeper_event_queue_persistence.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; owner_nonce : int
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

type source_ack_result =
  | Acked of transition_receipt
  | Already_acked of transition_receipt
  | Ack_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }


let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus then queue else Keeper_event_queue.enqueue queue stimulus
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

let enqueue ~base_path name stimulus =
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
  | Ok () -> ()
  | Error message ->
    Log.Keeper.error
      "registry: durable enqueue failed name=%s base_path=%s post_id=%s: %s"
      name
      base_path
      stimulus.Keeper_event_queue.post_id
      message
;;

let enqueue_durable_result ~base_path name stimulus =
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
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _
  | Keeper_event_queue.Completion_authority_rejected _ ->
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

let enqueue_if_missing_durable_result ~base_path ~event_id name stimulus =
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

type enqueue_stimulus_durable_result =
  | Stimulus_enqueued
  | Stimulus_already_present
  | Stimulus_storage_error of string

type transfer_projection_result =
  | Transfer_projection_committed
  | Transfer_projection_already_committed
  | Transfer_projection_storage_error of string
  | Transfer_projection_shutdown_reserved of Keeper_shutdown_types.Operation_id.t

let enqueue_stimulus_durable_result ~base_path name stimulus =
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

let project_accepted_transfer_durable_result ~base_path name ~transfer =
  match
    Keeper_turn_admission.run_durable_intake_if_open
      ~base_path
      ~keeper_name:name
      (fun () ->
         Keeper_event_queue_persistence.project_accepted_transfer_result
           ~base_path
           ~keeper_name:name
           ~after_commit:(publish_pending ~base_path name)
           ~transfer)
  with
  | Keeper_turn_admission.Intake_shutdown_reserved operation_id ->
    Transfer_projection_shutdown_reserved operation_id
  | Keeper_turn_admission.Intake_committed result ->
    (match result with
     | Ok Keeper_event_queue_persistence.Transfer_projected ->
       Transfer_projection_committed
     | Ok Keeper_event_queue_persistence.Transfer_already_projected ->
       Transfer_projection_already_committed
     | Error detail -> Transfer_projection_storage_error detail)
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
  enqueue_durable_result ~base_path keeper_name stimulus
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

let existing_durable_state_result ~base_path name =
  Keeper_event_queue_persistence.load_existing_state_result
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

let peek_when_result ~base_path name ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.peek_when_result
      ~base_path
      ~keeper_name:name
      ~ready
;;

let select_when_result ~base_path name ~ready =
  match Keeper_registry.get ~base_path name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" name)
  | Some _ ->
    Keeper_event_queue_persistence.select_when_result
      ~base_path
      ~keeper_name:name
      ~ready
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
      ~current_owner_nonce
      ~applied_at
      ~cancellation
  =
  Keeper_event_queue_persistence.cancel_pending_accepted_result
    ~base_path
    ~keeper_name:name
    ~current_owner_nonce
    ~applied_at
    ~cancellation
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let transfer_pending_accepted_result
      ~base_path
      name
      ~current_owner_nonce
      ~applied_at
      ~transfer
  =
  Keeper_event_queue_persistence.transfer_pending_accepted_result
    ~base_path
    ~keeper_name:name
    ~current_owner_nonce
    ~applied_at
    ~transfer
    ~after_commit:(publish_pending ~base_path name)
    ()
;;

let ack_pending_source_terminal_result
      ~base_path
      name
      ~current_owner_nonce
      ~acked_at
      ~source_terminal
  =
  Keeper_event_queue_persistence.ack_pending_source_terminal_result
    ~base_path
    ~keeper_name:name
    ~current_owner_nonce
    ~acked_at
    ~source_terminal
    ~after_commit:(publish_pending ~base_path name)
    ()
  |> Result.map (function
    | Transition_applied receipt -> Acked receipt
    | Transition_already_applied receipt -> Already_acked receipt
    | Transition_committed_followup_failed { receipt; stage; detail } ->
      Ack_committed_followup_failed { receipt; stage; detail })
;;

let terminalize_pending_turn_attempt_result
      ~base_path
      name
      ~current_owner_nonce
      ~applied_at
      ~selection
      ~detail
  =
  Keeper_event_queue_persistence.terminalize_pending_turn_attempt_result
    ~base_path
    ~keeper_name:name
    ~current_owner_nonce
    ~applied_at
    ~selection
    ~detail
    ~after_commit:(publish_pending ~base_path name)
    ()
  |> Result.map (function
    | Transition_applied receipt -> Acked receipt
    | Transition_already_applied receipt -> Already_acked receipt
    | Transition_committed_followup_failed { receipt; stage; detail } ->
      Ack_committed_followup_failed { receipt; stage; detail })
;;
