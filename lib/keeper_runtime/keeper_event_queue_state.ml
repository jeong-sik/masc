type exact_execution_terminal_cause =
  | Exact_execution_failed
  | Exact_execution_cancelled
  | Domain_invalid_output
  | Compaction_produced_no_reduction
  | Compaction_increased_checkpoint
  | Invalid_structural_evidence
  | Invalid_structural_source_after_dispatch
  | Commit_admission_unavailable
  | Lifecycle_transition_failed_after_dispatch
  | Checkpoint_source_changed
  | Checkpoint_persistence_failed

type exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; transition : transition
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type t =
  { revision : int64
  ; pending : Keeper_event_queue.t
  ; last_transition : transition_receipt option
  ; projected_dispositions : transition_receipt list
  ; transition_outbox : outbox_entry list
  ; accepted_transfer_projections : accepted_transfer list
  }

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

let schema = "keeper.event_queue.state.v12"

let empty =
  { revision = 0L
  ; pending = Keeper_event_queue.empty
  ; last_transition = None
  ; projected_dispositions = []
  ; transition_outbox = []
  ; accepted_transfer_projections = []
  }
;;

let revision state = state.revision
let pending state = state.pending
let last_transition state = state.last_transition

let disposition_operation_id = function
  | Cancel_accepted cancellation -> cancellation.operator_operation_id
  | Transfer_accepted transfer -> transfer.operator_operation_id
  | Ack_source_terminal source_terminal ->
    source_terminal.operator_operation_id
;;

let projected_dispositions state =
  Option.to_list state.last_transition @ state.projected_dispositions
;;

let projected_transition_receipts = projected_dispositions

let transition_outbox state = state.transition_outbox
let accepted_transfer_projections state = state.accepted_transfer_projections

let accounted_stimuli state =
  Keeper_event_queue.to_list state.pending
  @ List.concat_map
      (fun (entry : outbox_entry) -> entry.stimuli)
      state.transition_outbox
;;

let project_accepted_transfer (transfer : accepted_transfer) state =
  let same_operation (candidate : accepted_transfer) =
    String.equal candidate.operator_operation_id transfer.operator_operation_id
  in
  match List.find_opt same_operation state.accepted_transfer_projections with
  | Some existing when existing = transfer -> Ok (state, Transfer_already_projected)
  | Some _ -> Error "target transfer operation ID conflicts with its durable projection"
  | None ->
    let same_source (candidate : accepted_transfer) =
      Keeper_event_queue.stimulus_identity_equal candidate.source transfer.source
    in
    (match List.find_opt same_source state.accepted_transfer_projections with
     | Some _ ->
       Error "target transfer source identity was already projected by another operation"
     | None ->
       let matching =
         accounted_stimuli state
         |> List.filter (fun candidate ->
           Keeper_event_queue.stimulus_identity_equal candidate transfer.source)
       in
       (match matching with
        | [] ->
          let pending = Keeper_event_queue.enqueue state.pending transfer.source in
          Ok
            ( { state with
                pending
              ; accepted_transfer_projections =
                  state.accepted_transfer_projections @ [ transfer ]
              }
            , Transfer_projected )
        | [ existing ] when existing = transfer.source ->
          Ok
            ( { state with
                accepted_transfer_projections =
                  state.accepted_transfer_projections @ [ transfer ]
              }
            , Transfer_already_projected )
        | [ _ ] ->
          Error "target transfer source identity has a different durable snapshot"
        | _ :: _ :: _ ->
          Error "target transfer source identity is duplicated in durable state"))
;;

let mark_transition_projected ~transition_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id ->
    let projected_dispositions =
      match state.last_transition with
      | Some receipt ->
        receipt :: state.projected_dispositions
      | None -> state.projected_dispositions
    in
    Ok
      { state with
        last_transition = Some entry.receipt
      ; projected_dispositions
      ; transition_outbox = []
      }
  | [] ->
    (match
       List.find_opt
         (fun receipt -> String.equal receipt.transition_id transition_id)
         (projected_transition_receipts state)
     with
     | Some _ -> Ok state
     | None ->
       Error (Printf.sprintf "event queue transition not found: %s" transition_id))
  | [ _ ] ->
    Error (Printf.sprintf "event queue transition not found: %s" transition_id)
  | _ :: _ :: _ -> Error "event queue state has multiple unprojected transitions"
;;
let with_pending pending state = { state with pending }
let with_revision revision state = { state with revision }

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus
;;

let enqueue_if_missing queue stimulus =
  if queue_contains queue stimulus
  then queue
  else Keeper_event_queue.enqueue queue stimulus
;;

let transition_outbox_blocked state = state.transition_outbox <> []

let rec dequeue_first_ready ~ready skipped pending =
  match Keeper_event_queue.dequeue pending with
  | None -> None
  | Some (stimulus, rest) when ready stimulus ->
    Some (stimulus, Keeper_event_queue.prepend_list (List.rev skipped) rest)
  | Some (stimulus, rest) ->
    dequeue_first_ready ~ready (stimulus :: skipped) rest
;;

let peek_when ~ready state =
  match dequeue_first_ready ~ready [] state.pending with
  | None -> None
  | Some (stimulus, _) -> Some stimulus
;;

let validate_pending_selection
      ~(selection : Keeper_event_queue.stimulus)
      state
  =
  let matching =
    Keeper_event_queue.to_list state.pending
    |> List.filter (Keeper_event_queue.stimulus_identity_equal selection)
  in
  match matching with
  | [ actual ] when actual = selection -> Ok ()
  | [ _ ] -> Error "event queue pending selection typed snapshot changed"
  | [] -> Error "event queue pending selection is no longer present"
  | _ :: _ :: _ ->
    Error "event queue pending selection is present more than once"
;;

let ack_pending ~(selection : Keeper_event_queue.stimulus) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    let retained =
      Keeper_event_queue.to_list state.pending
      |> List.filter
           (Fun.negate
              (Keeper_event_queue.stimulus_identity_equal selection))
    in
    let pending =
      List.fold_left
        Keeper_event_queue.enqueue
        Keeper_event_queue.empty
        retained
    in
    Ok { state with pending }
;;

let ( let* ) = Result.bind

let exact_execution_terminal_cause_label = function
  | Exact_execution_failed -> "exact_execution_failed"
  | Exact_execution_cancelled -> "exact_execution_cancelled"
  | Domain_invalid_output -> "domain_invalid_output"
  | Compaction_produced_no_reduction -> "compaction_produced_no_reduction"
  | Compaction_increased_checkpoint -> "compaction_increased_checkpoint"
  | Invalid_structural_evidence -> "invalid_structural_evidence"
  | Invalid_structural_source_after_dispatch ->
    "invalid_structural_source_after_dispatch"
  | Commit_admission_unavailable -> "commit_admission_unavailable"
  | Lifecycle_transition_failed_after_dispatch ->
    "lifecycle_transition_failed_after_dispatch"
  | Checkpoint_source_changed -> "checkpoint_source_changed"
  | Checkpoint_persistence_failed -> "checkpoint_persistence_failed"
;;

let exact_execution_terminal_to_string terminal =
  Printf.sprintf
    "%s:slot_id=%s:call_id=%s:plan_fingerprint=%s:request_body_sha256=%s"
    (exact_execution_terminal_cause_label terminal.cause)
    terminal.slot_id
    terminal.call_id
    terminal.plan_fingerprint
    terminal.request_body_sha256
;;

let pending_transition_id = function
  | Cancel_accepted cancellation ->
    "pending-cancel:" ^ cancellation.operator_operation_id
  | Transfer_accepted transfer ->
    "pending-transfer:" ^ transfer.operator_operation_id
  | Ack_source_terminal source_terminal ->
    "pending-source-terminal-ack:" ^ source_terminal.operator_operation_id
;;

let event_id_of_transition transition_id =
  "keeper-event-queue-transition:" ^ transition_id
;;

let transition_equal left right =
  match left, right with
  | Cancel_accepted left, Cancel_accepted right -> left = right
  | Transfer_accepted left, Transfer_accepted right -> left = right
  | Ack_source_terminal left, Ack_source_terminal right ->
    left = right
  | _ -> false
;;

let transition_receipt_equal left right =
  String.equal left.transition_id right.transition_id
  && String.equal left.event_id right.event_id
  && Float.equal left.applied_at right.applied_at
  && left.transition = right.transition
;;

let validate_accepted_cancellation (cancellation : accepted_cancellation) =
  if String.equal (String.trim cancellation.source.post_id) ""
  then Error "accepted cancellation source post id must not be empty"
  else if Int64.compare cancellation.source_revision 0L < 0
  then Error "accepted cancellation source revision must not be negative"
  else if cancellation.owner_nonce < 0
  then Error "accepted cancellation owner generation must not be negative"
  else if String.equal (String.trim cancellation.operator_operation_id) ""
  then Error "accepted cancellation operator operation id must not be empty"
  else if String.equal (String.trim cancellation.reason) ""
  then Error "accepted cancellation reason must not be empty"
  else Ok ()
;;

let validate_accepted_transfer (transfer : accepted_transfer) =
  if String.equal (String.trim transfer.source.post_id) ""
  then Error "accepted transfer source post id must not be empty"
  else if Int64.compare transfer.source_revision 0L < 0
  then Error "accepted transfer source revision must not be negative"
  else if transfer.owner_nonce < 0
  then Error "accepted transfer owner generation must not be negative"
  else if String.equal (String.trim transfer.operator_operation_id) ""
  then Error "accepted transfer operator operation id must not be empty"
  else if String.equal (String.trim transfer.from_keeper) ""
  then Error "accepted transfer source Keeper must not be empty"
  else if String.equal (String.trim transfer.to_keeper) ""
  then Error "accepted transfer target Keeper must not be empty"
  else if String.equal transfer.from_keeper transfer.to_keeper
  then Error "accepted transfer source and target Keepers must differ"
  else Ok ()
;;

let source_terminal_receipt_of_stimulus source =
  match source.Keeper_event_queue.payload with
  | Keeper_event_queue.Fusion_completed completion ->
    Ok (Fusion_terminal completion)
  | Keeper_event_queue.Bg_completed completion ->
    Ok (Background_job_terminal completion)
  | Keeper_event_queue.Hitl_resolved resolution -> Ok (Hitl_terminal resolution)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _ ->
    Error "source event does not carry a typed terminal receipt"
;;

let validate_accepted_source_terminal source_terminal =
  if String.equal (String.trim source_terminal.source.post_id) ""
  then Error "source-terminal ACK source post id must not be empty"
  else if Int64.compare source_terminal.source_revision 0L < 0
  then Error "source-terminal ACK source revision must not be negative"
  else if source_terminal.owner_nonce < 0
  then Error "source-terminal ACK owner generation must not be negative"
  else if String.equal (String.trim source_terminal.operator_operation_id) ""
  then Error "source-terminal ACK operation id must not be empty"
  else
    let* receipt = source_terminal_receipt_of_stimulus source_terminal.source in
    if receipt = source_terminal.source_receipt
    then Ok ()
    else Error "source-terminal ACK receipt does not match source payload"
;;

let validate_transition = function
  | Cancel_accepted cancellation -> validate_accepted_cancellation cancellation
  | Transfer_accepted transfer -> validate_accepted_transfer transfer
  | Ack_source_terminal source_terminal ->
    validate_accepted_source_terminal source_terminal
;;

(* Pure receipt-vs-stimuli invariant shared by the live pending-transition
   path and the persist decode boundary. *)
let validate_transition_for_stimuli transition stimuli =
  match transition, stimuli with
  | Cancel_accepted cancellation, [ source ] when cancellation.source = source ->
    Ok ()
  | Cancel_accepted _, [ _ ] ->
    Error "accepted cancellation source does not match its exact event stimulus"
  | Cancel_accepted _, _ ->
    Error "accepted cancellation requires exactly one accepted event stimulus"
  | Transfer_accepted transfer, [ source ] when transfer.source = source -> Ok ()
  | Transfer_accepted _, [ _ ] ->
    Error "accepted transfer source does not match its exact event stimulus"
  | Transfer_accepted _, _ ->
    Error "accepted transfer requires exactly one accepted event stimulus"
  | Ack_source_terminal source_terminal, [ source ]
    when source_terminal.source = source -> Ok ()
  | Ack_source_terminal _, [ _ ] ->
    Error "source-terminal receipt does not match its exact event stimulus"
  | Ack_source_terminal _, _ ->
    Error "source-terminal ACK requires exactly one accepted event stimulus"
;;

let receipt_for_pending_transition ~applied_at ~transition =
  let transition_id = pending_transition_id transition in
  { transition_id
  ; event_id = event_id_of_transition transition_id
  ; applied_at
  ; transition
  }
;;

let apply_pending_transition ~applied_at ~transition ~source ~pending state =
  if not (Float.is_finite applied_at)
  then Error "event queue transition application time must be finite"
  else
    let* () = validate_transition transition in
    let* () = validate_transition_for_stimuli transition [ source ] in
    let receipt = receipt_for_pending_transition ~applied_at ~transition in
    Ok
      ( { state with
          pending
        ; transition_outbox = [ { receipt; stimuli = [ source ] } ]
        }
      , Transition_applied receipt )
;;

let find_prior_receipt transition_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id -> Some entry.receipt
  | [] | [ _ ] ->
    List.find_opt
      (fun receipt -> String.equal receipt.transition_id transition_id)
      (projected_transition_receipts state)
  | _ :: _ :: _ -> None
;;

let prior_disposition_by_operation_id operation_id state =
  let is_same_operation receipt =
    String.equal
      (disposition_operation_id receipt.transition)
      operation_id
  in
  match state.transition_outbox with
  | [ entry ] when is_same_operation entry.receipt -> Some entry.receipt
  | [] | [ _ ] ->
    List.find_opt is_same_operation (projected_dispositions state)
  | _ :: _ :: _ -> None
;;

let accepted_pending_cancellation_replay cancellation state =
  let requested = Cancel_accepted cancellation in
  match
    prior_disposition_by_operation_id cancellation.operator_operation_id state
  with
  | None -> Ok None
  | Some receipt when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "accepted cancellation operation conflict: %s"
         cancellation.operator_operation_id)
;;

let cancel_pending_accepted
      ~current_owner_nonce
      ~applied_at
      ~cancellation
      state
  =
  let transition = Cancel_accepted cancellation in
  match accepted_pending_cancellation_replay cancellation state with
  | Error _ as error -> error
  | Ok (Some receipt) ->
    Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_cancellation cancellation in
    let* () =
      if Int.equal current_owner_nonce cancellation.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation owner generation changed: expected %d, current %d"
             cancellation.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision cancellation.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted cancellation source revision changed: expected %Ld, current %Ld"
             cancellation.source_revision
             state.revision)
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot cancel pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal cancellation.source source)
    in
    (match matching with
     | [] -> Error "accepted cancellation source is not pending"
     | _ :: _ :: _ -> Error "accepted cancellation source identity is duplicated"
     | [ source ] when source <> cancellation.source ->
       Error "accepted cancellation source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition
         ~source
         ~pending
         state)
;;

let accepted_pending_transfer_replay transfer state =
  let requested = Transfer_accepted transfer in
  match prior_disposition_by_operation_id transfer.operator_operation_id state with
  | None -> Ok None
  | Some receipt when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "accepted transfer operation conflict: %s"
         transfer.operator_operation_id)
;;

let transfer_pending_accepted
      ~current_owner_nonce
      ~applied_at
      ~transfer
      state
  =
  let transition = Transfer_accepted transfer in
  match accepted_pending_transfer_replay transfer state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_transfer transfer in
    let* () =
      if Int.equal current_owner_nonce transfer.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted transfer owner generation changed: expected %d, current %d"
             transfer.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision transfer.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "accepted transfer source revision changed: expected %Ld, current %Ld"
             transfer.source_revision
             state.revision)
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot transfer pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal transfer.source source)
    in
    (match matching with
     | [] -> Error "accepted transfer source is not pending"
     | _ :: _ :: _ -> Error "accepted transfer source identity is duplicated"
     | [ source ] when source <> transfer.source ->
       Error "accepted transfer source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition
         ~source
         ~pending
         state)
;;

let accepted_pending_source_terminal_ack_replay source_terminal state =
  let requested = Ack_source_terminal source_terminal in
  match
    prior_disposition_by_operation_id
      source_terminal.operator_operation_id
      state
  with
  | None -> Ok None
  | Some receipt when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "source-terminal ACK operation conflict: %s"
         source_terminal.operator_operation_id)
;;

let ack_pending_source_terminal
      ~current_owner_nonce
      ~applied_at
      ~source_terminal
      state
  =
  let ack = Ack_source_terminal source_terminal in
  match accepted_pending_source_terminal_ack_replay source_terminal state with
  | Error _ as error -> error
  | Ok (Some receipt) -> Ok (state, Transition_already_applied receipt)
  | Ok None ->
    let* () = validate_accepted_source_terminal source_terminal in
    let* () =
      if Int.equal current_owner_nonce source_terminal.owner_nonce
      then Ok ()
      else
        Error
          (Printf.sprintf
             "source-terminal ACK owner generation changed: expected %d, current %d"
             source_terminal.owner_nonce
             current_owner_nonce)
    in
    let* () =
      if Int64.equal state.revision source_terminal.source_revision
      then Ok ()
      else
        Error
          (Printf.sprintf
             "source-terminal ACK source revision changed: expected %Ld, current %Ld"
             source_terminal.source_revision
             state.revision)
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot ACK pending source while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list state.pending
      |> List.partition (fun source ->
        Keeper_event_queue.stimulus_identity_equal source_terminal.source source)
    in
    (match matching with
     | [] -> Error "source-terminal ACK source is not pending"
     | _ :: _ :: _ ->
       Error "source-terminal ACK source identity is duplicated"
     | [ source ] when source <> source_terminal.source ->
       Error "source-terminal ACK source snapshot changed"
     | [ source ] ->
       let pending =
         List.fold_left
           Keeper_event_queue.enqueue
           Keeper_event_queue.empty
           retained
       in
       apply_pending_transition
         ~applied_at
         ~transition:ack
         ~source
         ~pending
         state)
;;

let restore_pending_transition entry state apply =
  let* replayed, result = apply state in
  let actual_receipt =
    match result with
    | Transition_applied receipt | Transition_already_applied receipt -> receipt
  in
  match replayed.transition_outbox with
  | [ actual ]
    when transition_receipt_equal entry.receipt actual_receipt
         && actual.stimuli = entry.stimuli ->
    Ok replayed
  | [] | [ _ ] | _ :: _ :: _ ->
    Error
      (Printf.sprintf
         "pending transition WAL replay conflict: %s"
         entry.receipt.transition_id)
;;

let replay_transition_outbox_entry entry state =
  match state.transition_outbox with
  | [ current ] when current = entry -> Ok state
  | [ current ] ->
    Error
      (Printf.sprintf
         "event queue WAL conflicts with checkpointed outbox: %s"
         current.receipt.transition_id)
  | _ :: _ :: _ -> Error "event queue checkpoint contains multiple outbox entries"
  | [] ->
    (match
       List.find_opt
         (fun receipt -> transition_receipt_equal receipt entry.receipt)
         (projected_transition_receipts state)
     with
     | Some _ -> Ok state
     | None ->
       (match entry.receipt.transition, entry.stimuli with
     | Cancel_accepted cancellation, [ source ] when source = cancellation.source ->
       restore_pending_transition entry state (fun state ->
         cancel_pending_accepted
           ~current_owner_nonce:cancellation.owner_nonce
           ~applied_at:entry.receipt.applied_at
           ~cancellation
           state)
     | Cancel_accepted _, [ _ ] ->
       Error "pending cancellation WAL source conflicts with its receipt"
     | Cancel_accepted _, ([] | _ :: _ :: _) ->
       Error "pending cancellation WAL must carry exactly one source"
     | Transfer_accepted transfer, [ source ] when source = transfer.source ->
       restore_pending_transition entry state (fun state ->
         transfer_pending_accepted
           ~current_owner_nonce:transfer.owner_nonce
           ~applied_at:entry.receipt.applied_at
           ~transfer
           state)
     | Transfer_accepted _, [ _ ] ->
       Error "pending transfer WAL source conflicts with its receipt"
     | Transfer_accepted _, ([] | _ :: _ :: _) ->
       Error "pending transfer WAL must carry exactly one source"
     | Ack_source_terminal source_terminal, [ source ]
       when source = source_terminal.source ->
       restore_pending_transition entry state (fun state ->
         ack_pending_source_terminal
           ~current_owner_nonce:source_terminal.owner_nonce
           ~applied_at:entry.receipt.applied_at
           ~source_terminal
           state)
     | Ack_source_terminal _, [ _ ] ->
       Error "pending source-terminal ACK WAL source conflicts with its receipt"
     | Ack_source_terminal _, ([] | _ :: _ :: _) ->
       Error "pending source-terminal ACK WAL must carry exactly one source"
    ))
;;

let remove_by_post_id post_id state =
  let removed, pending =
    Keeper_event_queue.remove_by_post_id post_id state.pending
  in
  Keeper_event_queue.uniq_stimuli removed, { state with pending }
;;

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be a JSON object")
;;

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)
;;

let exact_fields ~context ~expected fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      if not (List.exists (String.equal name) expected)
      then Error (Printf.sprintf "%s contains unknown field %s" context name)
      else if List.exists (String.equal name) seen
      then Error (Printf.sprintf "%s contains duplicate field %s" context name)
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let string_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be a string" context name)
;;

let float_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
;;

let int_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
;;

let int64_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s.%s must be an int64" context name))
  | _ -> Error (Printf.sprintf "%s.%s must be an int64" context name)
;;

let list_field ~context name parse fields =
  let* value = required_field ~context name fields in
  match value with
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* parsed = parse value in
        loop (parsed :: acc) rest
    in
    loop [] values
  | _ -> Error (Printf.sprintf "%s.%s must be a list" context name)
;;

let int64_json value = `Intlit (Int64.to_string value)

let no_compaction_reason_label = function
  | No_eligible_history -> "no_eligible_history"
  | Invalid_structural_source -> "invalid_structural_source"
  | Exact_lane_unconfigured -> "exact_lane_unconfigured"
  | Exact_execution_terminal terminal ->
    exact_execution_terminal_cause_label terminal.cause
;;

let no_compaction_reason_to_string = function
  | Exact_execution_terminal terminal -> exact_execution_terminal_to_string terminal
  | reason -> no_compaction_reason_label reason
;;

let transition_to_yojson = function
  | Cancel_accepted cancellation ->
    `Assoc
      [ "kind", `String "cancel_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson cancellation.source
      ; "source_revision", int64_json cancellation.source_revision
      ; "owner_nonce", `Int cancellation.owner_nonce
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
  | Transfer_accepted transfer ->
    `Assoc
      [ "kind", `String "transfer_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson transfer.source
      ; "source_revision", int64_json transfer.source_revision
      ; "owner_nonce", `Int transfer.owner_nonce
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ]
  | Ack_source_terminal source_terminal ->
    let receipt_kind =
      match source_terminal.source_receipt with
      | Fusion_terminal _ -> "fusion_terminal"
      | Background_job_terminal _ -> "background_job_terminal"
      | Hitl_terminal _ -> "hitl_terminal"
    in
    `Assoc
      [ "kind", `String "ack_source_terminal"
      ; "source", Keeper_event_queue.stimulus_to_yojson source_terminal.source
      ; "source_revision", int64_json source_terminal.source_revision
      ; "owner_nonce", `Int source_terminal.owner_nonce
      ; "operator_operation_id", `String source_terminal.operator_operation_id
       ; "source_receipt_kind", `String receipt_kind
       ]
;;

let transition_of_yojson json =
  let context = "event queue transition" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "cancel_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "operator_operation_id"
          ; "reason"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = int_field ~context "owner_nonce" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* reason = string_field ~context "reason" fields in
    let cancellation =
      { source; source_revision; owner_nonce; operator_operation_id; reason }
    in
    let* () = validate_accepted_cancellation cancellation in
    Ok (Cancel_accepted cancellation)
  | "transfer_accepted" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "operator_operation_id"
          ; "from_keeper"
          ; "to_keeper"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = int_field ~context "owner_nonce" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let transfer =
      { source
      ; source_revision
      ; owner_nonce
      ; operator_operation_id
      ; from_keeper
      ; to_keeper
      }
    in
    let* () = validate_accepted_transfer transfer in
    Ok (Transfer_accepted transfer)
  | "ack_source_terminal" ->
    let* () =
      exact_fields
        ~context
        ~expected:
          [ "kind"
          ; "source"
          ; "source_revision"
          ; "owner_nonce"
          ; "operator_operation_id"
          ; "source_receipt_kind"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_revision = int64_field ~context "source_revision" fields in
    let* owner_nonce = int_field ~context "owner_nonce" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* source_receipt_kind =
      string_field ~context "source_receipt_kind" fields
    in
    let* source_receipt = source_terminal_receipt_of_stimulus source in
    let expected_kind =
      match source_receipt with
      | Fusion_terminal _ -> "fusion_terminal"
      | Background_job_terminal _ -> "background_job_terminal"
      | Hitl_terminal _ -> "hitl_terminal"
    in
    let* () =
      if String.equal source_receipt_kind expected_kind
      then Ok ()
      else Error "source-terminal receipt kind does not match source payload"
    in
    let source_terminal =
      { source
      ; source_revision
      ; owner_nonce
      ; operator_operation_id
      ; source_receipt
      }
    in
    let* () = validate_accepted_source_terminal source_terminal in
    Ok (Ack_source_terminal source_terminal)
  | kind -> Error (Printf.sprintf "unknown event queue transition kind: %s" kind)
;;

let accepted_transfer_projection_to_yojson (transfer : accepted_transfer) =
  transition_to_yojson (Transfer_accepted transfer)
;;

let accepted_transfer_projection_of_yojson json =
  let* transition = transition_of_yojson json in
  match transition with
  | Transfer_accepted transfer -> Ok transfer
  | Cancel_accepted _
  | Ack_source_terminal _ ->
    Error "target transfer projection must contain transfer_accepted"
;;

let transition_receipt_to_yojson receipt =
  `Assoc
    [ "transition_id", `String receipt.transition_id
    ; "event_id", `String receipt.event_id
    ; "applied_at_unix", `Float receipt.applied_at
    ; "transition", transition_to_yojson receipt.transition
    ]
;;

let transition_receipt_of_yojson json =
  let context = "event queue transition receipt" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "transition_id"
        ; "event_id"
        ; "applied_at_unix"
        ; "transition"
        ]
      fields
  in
  let* receipt_transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* applied_at = float_field ~context "applied_at_unix" fields in
  let* transition_json = required_field ~context "transition" fields in
  let* transition = transition_of_yojson transition_json in
  if not (Float.is_finite applied_at)
  then Error "event queue receipt application time must be finite"
  else if
    not
      (String.equal
         receipt_transition_id
         (pending_transition_id transition))
  then Error (Printf.sprintf "event queue receipt transition id mismatch: %s" receipt_transition_id)
  else if not (String.equal event_id (event_id_of_transition receipt_transition_id))
  then Error (Printf.sprintf "event queue receipt event id mismatch: %s" event_id)
  else
    Ok
      { transition_id = receipt_transition_id
      ; event_id
      ; applied_at
      ; transition
      }
;;

let outbox_entry_to_yojson entry =
  `Assoc
    [ "receipt", transition_receipt_to_yojson entry.receipt
    ; "stimuli", `List (List.map Keeper_event_queue.stimulus_to_yojson entry.stimuli)
    ]
;;

let outbox_entry_of_yojson json =
  let context = "event queue outbox entry" in
  let* fields = assoc_fields ~context json in
  let* receipt_json = required_field ~context "receipt" fields in
  let* receipt = transition_receipt_of_yojson receipt_json in
  let* stimuli =
    list_field ~context "stimuli" Keeper_event_queue.stimulus_of_yojson fields
  in
  (* Re-enforce the commit-time receipt-vs-stimuli invariant at the decode
     boundary; malformed typed terminal receipts are rejected as [Error]. *)
  let* () = validate_transition_for_stimuli receipt.transition stimuli in
  Ok { receipt; stimuli }
;;

let to_yojson state =
  `Assoc
    [ "schema", `String schema
    ; "revision", int64_json state.revision
    ; "pending", Keeper_event_queue.queue_to_yojson state.pending
    ; ( "last_transition"
      , match state.last_transition with
        | None -> `Null
        | Some receipt -> transition_receipt_to_yojson receipt )
    ; ( "projected_dispositions"
      , `List
          (List.map
             transition_receipt_to_yojson
             state.projected_dispositions) )
    ; ( "transition_outbox"
      , `List (List.map outbox_entry_to_yojson state.transition_outbox) )
    ; ( "accepted_transfer_projections"
      , `List
          (List.map
             accepted_transfer_projection_to_yojson
             state.accepted_transfer_projections) )
    ]
;;

let duplicate_by key values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      let key = key value in
      if List.exists (String.equal key) seen
      then Some key
      else loop (key :: seen) rest
  in
  loop [] values
;;

let duplicate_transfer_source (transfers : accepted_transfer list) =
  let rec loop seen (l : accepted_transfer list) =
    match l with
    | [] -> None
    | transfer :: rest ->
      (match
         List.find_opt
           (fun (prior : accepted_transfer) ->
              Keeper_event_queue.stimulus_identity_equal
                prior.source
                transfer.source)
           seen
       with
       | Some prior -> Some (prior, transfer)
       | None -> loop (transfer :: seen) rest)
  in
  loop [] transfers
;;

let validate_state state =
  if Int64.compare state.revision 0L < 0
  then Error "event queue revision must not be negative"
  else if List.length state.transition_outbox > 1
  then Error "event queue state must contain at most one unprojected transition"
  else if
    match state.transition_outbox with
    | [ entry ] ->
      List.exists
        (fun receipt ->
           String.equal receipt.transition_id entry.receipt.transition_id)
        (projected_transition_receipts state)
    | [] | _ :: _ :: _ -> false
  then Error "event queue projected ledger duplicates the unprojected transition"
  else
    let* () =
      match
        duplicate_by
          (fun entry -> entry.receipt.transition_id)
          state.transition_outbox
      with
      | Some transition_id ->
        Error (Printf.sprintf "duplicate event queue transition id: %s" transition_id)
      | None -> Ok ()
    in
    let* () =
      match
        duplicate_by
          (fun receipt -> receipt.transition_id)
          (projected_transition_receipts state)
      with
      | Some transition_id ->
        Error
          (Printf.sprintf
             "duplicate projected event queue transition id: %s"
             transition_id)
      | None -> Ok ()
    in
    let disposition_operation_ids =
      List.map
        (fun receipt -> disposition_operation_id receipt.transition)
        (projected_dispositions state)
      @ List.map
          (fun entry ->
             disposition_operation_id entry.receipt.transition)
          state.transition_outbox
    in
    let* () =
      match duplicate_by Fun.id disposition_operation_ids with
      | Some operation_id ->
        Error
          (Printf.sprintf
             "duplicate durable disposition operation id: %s"
             operation_id)
      | None -> Ok ()
    in
    let* () =
      match
        duplicate_by
          (fun (transfer : accepted_transfer) ->
             transfer.operator_operation_id)
          state.accepted_transfer_projections
      with
      | Some operation_id ->
        Error
          (Printf.sprintf
             "duplicate target transfer projection operation id: %s"
             operation_id)
      | None -> Ok ()
    in
    (match duplicate_transfer_source state.accepted_transfer_projections with
     | Some _ -> Error "duplicate target transfer projection source identity"
     | None -> Ok state)
;;

let of_yojson json =
  let context = "keeper event queue state" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  let* () =
    if String.equal schema_value schema
    then Ok ()
    else
      Error
        (Printf.sprintf "unsupported keeper event queue state schema: %s" schema_value)
  in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "schema"
        ; "revision"
        ; "pending"
        ; "last_transition"
        ; "projected_dispositions"
        ; "transition_outbox"
        ; "accepted_transfer_projections"
        ]
      fields
  in
  let* revision = int64_field ~context "revision" fields in
  let* pending_json = required_field ~context "pending" fields in
  let* pending = Keeper_event_queue.queue_of_yojson pending_json in
  let* transition_outbox =
    list_field ~context "transition_outbox" outbox_entry_of_yojson fields
  in
  let* last_transition =
    match List.assoc_opt "last_transition" fields with
    | Some `Null -> Ok None
    | Some json -> transition_receipt_of_yojson json |> Result.map Option.some
    | None -> Error "keeper event queue state missing required field last_transition"
  in
  let* projected_dispositions =
    list_field
      ~context
      "projected_dispositions"
      transition_receipt_of_yojson
      fields
  in
  let* accepted_transfer_projections =
    list_field
      ~context
      "accepted_transfer_projections"
      accepted_transfer_projection_of_yojson
      fields
  in
  validate_state
    { revision
    ; pending
    ; last_transition
    ; projected_dispositions
    ; transition_outbox
    ; accepted_transfer_projections
    }
;;
