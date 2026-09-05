type accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
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

type projected_disposition_kind =
  | Projected_cancel of { reason_ref : string }
  | Projected_transfer of
      { from_keeper : string
      ; to_keeper : string
      ; target_trace_id : Keeper_id.Trace_id.t
      }
  | Projected_fusion_terminal
  | Projected_hitl_terminal
  | Projected_turn_completed
  | Projected_turn_attempt_terminal

type projected_source_kind =
  | Source_board_signal
  | Source_board_attention
  | Source_bootstrap
  | Source_fusion_completed
  | Source_schedule_due
  | Source_connector_attention
  | Source_hitl_resolved
  | Source_ask_answered
  | Source_completion_authority_rejected
  | Source_task_cancelled
  | Source_workspace_message
  | Source_delegate_completed
  | Source_composition_completed

type projected_disposition_witness =
  { transition_id : string
  ; event_id : string
  ; applied_at : float
  ; operator_operation_id : string
  ; transition_ref : string
  ; source_ref : string
  ; post_id : string
  ; urgency : Keeper_event_queue.urgency
  ; source_arrived_at : float
  ; source_kind : projected_source_kind
  ; source_incarnation : int64
  ; kind : projected_disposition_kind
  }

type durable_disposition =
  | Current_receipt of transition_receipt
  | Projected_witness of projected_disposition_witness

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  }

type pending_selection =
  { source : Keeper_event_queue.stimulus
  ; admitted_revision : int64
  ; checkpoint_retentions : int
  }

type t =
  { revision : int64
  ; pending_entries : pending_selection list
  ; last_transition : transition_receipt option
  ; projected_dispositions : durable_disposition list
  ; transition_outbox : outbox_entry list
  ; accepted_transfer_projections : accepted_transfer list
  }

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt

type transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

let schema = "keeper.event_queue.state.v18"

let empty =
  { revision = 0L
  ; pending_entries = []
  ; last_transition = None
  ; projected_dispositions = []
  ; transition_outbox = []
  ; accepted_transfer_projections = []
  }
;;

let revision state = state.revision
let pending_selections state = state.pending_entries

let source_snapshot_ref source =
  Keeper_event_queue.stimulus_to_yojson source
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let disposition_reason_ref reason =
  ("keeper.event_queue.cancel_reason.v1\000" ^ reason)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let resolve_pending_selection
      ~source_ref
      ~source_incarnation
      state
  =
  let matching =
    List.filter
      (fun selection ->
         String.equal
           (source_snapshot_ref selection.source)
           source_ref)
      state.pending_entries
  in
  match matching with
  | [ selection ]
    when Int64.equal selection.admitted_revision source_incarnation ->
    Ok selection
  | [ _ ] -> Error "event queue source incarnation changed"
  | [] -> Error "event queue source is no longer pending"
  | _ -> Error "event queue source reference is ambiguous"
;;

let pending state =
  List.fold_left
    (fun queue entry ->
       Keeper_event_queue.enqueue queue entry.source)
    Keeper_event_queue.empty
    state.pending_entries
;;

let last_transition state = state.last_transition

let disposition_operation_id = function
  | Cancel_accepted cancellation -> cancellation.operator_operation_id
  | Transfer_accepted transfer -> transfer.operator_operation_id
  | Ack_source_terminal source_terminal ->
    source_terminal.operator_operation_id
;;

let projected_dispositions state =
  List.map (fun receipt -> Current_receipt receipt) (Option.to_list state.last_transition)
  @ state.projected_dispositions
;;

let transition_outbox state = state.transition_outbox
let accepted_transfer_projections state = state.accepted_transfer_projections

let transition_source = function
  | Cancel_accepted cancellation -> cancellation.source
  | Transfer_accepted transfer -> transfer.source
  | Ack_source_terminal terminal -> terminal.source
;;

let transition_source_incarnation = function
  | Cancel_accepted cancellation -> cancellation.source_incarnation
  | Transfer_accepted transfer -> transfer.source_incarnation
  | Ack_source_terminal terminal -> terminal.source_incarnation
;;

let projected_kind_of_transition = function
  | Cancel_accepted cancellation ->
    Projected_cancel { reason_ref = disposition_reason_ref cancellation.reason }
  | Transfer_accepted transfer ->
    Projected_transfer
      { from_keeper = transfer.from_keeper
      ; to_keeper = transfer.to_keeper
      ; target_trace_id = transfer.target_trace_id
      }
  | Ack_source_terminal { source_receipt = Fusion_terminal _; _ } ->
    Projected_fusion_terminal
  | Ack_source_terminal { source_receipt = Hitl_terminal _; _ } ->
    Projected_hitl_terminal
  | Ack_source_terminal { source_receipt = Turn_completed; _ } ->
    Projected_turn_completed
  | Ack_source_terminal { source_receipt = Turn_attempt_terminal _; _ } ->
    Projected_turn_attempt_terminal
;;

let projected_source_kind = function
  | Keeper_event_queue.Board_signal _ -> Source_board_signal
  | Keeper_event_queue.Board_attention _ -> Source_board_attention
  | Keeper_event_queue.Bootstrap -> Source_bootstrap
  | Keeper_event_queue.Fusion_completed _ -> Source_fusion_completed
  | Keeper_event_queue.Schedule_due _ -> Source_schedule_due
  | Keeper_event_queue.Connector_attention _ -> Source_connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Source_hitl_resolved
  | Keeper_event_queue.Ask_answered _ -> Source_ask_answered
  | Keeper_event_queue.Completion_authority_rejected _ ->
    Source_completion_authority_rejected
  | Keeper_event_queue.Task_cancelled _ -> Source_task_cancelled
  | Keeper_event_queue.Workspace_message _ -> Source_workspace_message
  | Keeper_event_queue.Delegate_completed _ -> Source_delegate_completed
  | Keeper_event_queue.Composition_completed _ -> Source_composition_completed
;;

let transition_ref transition =
  let source_ref = source_snapshot_ref (transition_source transition) in
  let fields =
    match transition with
    | Cancel_accepted cancellation ->
      [ "kind", `String "cancel"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string cancellation.source_incarnation)
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
    | Transfer_accepted transfer ->
      [ "kind", `String "transfer"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string transfer.source_incarnation)
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string transfer.target_trace_id)
      ]
    | Ack_source_terminal terminal ->
      let receipt_fields =
        match terminal.source_receipt with
        | Fusion_terminal _ -> [ "source_receipt_kind", `String "fusion" ]
        | Hitl_terminal _ -> [ "source_receipt_kind", `String "hitl" ]
        | Turn_completed -> [ "source_receipt_kind", `String "turn_completed" ]
        | Turn_attempt_terminal _ ->
          (* [detail] is diagnostic rather than operation authority: both the
             full-receipt replay contract and retry callers may supply a newer
             rendering for the same admitted attempt. Keep the compact
             fingerprint aligned with that typed replay identity. *)
          [ "source_receipt_kind", `String "turn_attempt_terminal" ]
      in
      [ "kind", `String "source_terminal"
      ; "source_ref", `String source_ref
      ; "source_incarnation", `Intlit (Int64.to_string terminal.source_incarnation)
      ; "operator_operation_id", `String terminal.operator_operation_id
      ]
      @ receipt_fields
  in
  `Assoc (("schema", `String "keeper.event_queue.transition_ref.v1") :: fields)
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let witness_of_receipt receipt =
  let transition = receipt.transition in
  let source = transition_source transition in
  { transition_id = receipt.transition_id
  ; event_id = receipt.event_id
  ; applied_at = receipt.applied_at
  ; operator_operation_id = disposition_operation_id transition
  ; transition_ref = transition_ref transition
  ; source_ref = source_snapshot_ref source
  ; post_id = source.post_id
  ; urgency = source.urgency
  ; source_arrived_at = source.arrived_at
  ; source_kind = projected_source_kind source.payload
  ; source_incarnation = transition_source_incarnation transition
  ; kind = projected_kind_of_transition transition
  }
;;

let durable_of_projected_receipt receipt =
  Projected_witness (witness_of_receipt receipt)
;;

let durable_transition_id = function
  | Current_receipt receipt -> receipt.transition_id
  | Projected_witness witness -> witness.transition_id
;;

let durable_operation_id = function
  | Current_receipt receipt -> disposition_operation_id receipt.transition
  | Projected_witness witness -> witness.operator_operation_id
;;

let witness_receipt_for_exact_transition witness transition =
  if String.equal witness.transition_ref (transition_ref transition)
  then
    Ok
      { transition_id = witness.transition_id
      ; event_id = witness.event_id
      ; applied_at = witness.applied_at
      ; transition
      }
  else Error "projected disposition transition fingerprint conflicts"
;;

let durable_matches_receipt disposition (receipt : transition_receipt) =
  match disposition with
  | Current_receipt current ->
    String.equal current.transition_id receipt.transition_id
    && String.equal current.event_id receipt.event_id
    && Float.equal current.applied_at receipt.applied_at
    && current.transition = receipt.transition
  | Projected_witness witness ->
    String.equal witness.transition_id receipt.transition_id
    && String.equal witness.event_id receipt.event_id
    && Float.equal witness.applied_at receipt.applied_at
    && String.equal witness.transition_ref (transition_ref receipt.transition)
;;

let transition_receipt_is_projected receipt state =
  List.exists
    (fun disposition -> durable_matches_receipt disposition receipt)
    (projected_dispositions state)
;;

let accounted_stimuli state =
  Keeper_event_queue.to_list (pending state)
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
    let matching =
      accounted_stimuli state
      |> List.filter (fun candidate ->
        Keeper_event_queue.stimulus_identity_equal candidate transfer.source)
    in
    (match matching with
     | [] ->
       Ok
         ( { state with
             pending_entries =
               state.pending_entries
               @ [ { source = transfer.source
                   ; admitted_revision = state.revision
                   ; checkpoint_retentions = 0
                   }
                 ]
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
       Error "target transfer source identity is duplicated in durable state")
;;

let mark_transition_projected ~transition_id state =
  match state.transition_outbox with
  | [ entry ] when String.equal entry.receipt.transition_id transition_id ->
    let projected_dispositions =
      match state.last_transition with
      | Some receipt ->
        durable_of_projected_receipt receipt :: state.projected_dispositions
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
         (fun disposition ->
            String.equal (durable_transition_id disposition) transition_id)
         (projected_dispositions state)
     with
     | Some _ -> Ok state
     | None ->
       Error (Printf.sprintf "event queue transition not found: %s" transition_id))
  | [ _ ] ->
    Error (Printf.sprintf "event queue transition not found: %s" transition_id)
  | _ :: _ :: _ -> Error "event queue state has multiple unprojected transitions"
;;
let with_pending pending state =
  let rec take_matching source skipped = function
    | [] -> None, List.rev skipped
    | entry :: rest
      when Keeper_event_queue.stimulus_identity_equal entry.source source
           && entry.source = source ->
      Some entry, List.rev_append skipped rest
    | entry :: rest -> take_matching source (entry :: skipped) rest
  in
  let rec reconcile available acc = function
    | [] -> List.rev acc
    | source :: rest ->
      let existing, available = take_matching source [] available in
      let entry =
        match existing with
        | Some entry -> entry
        | None -> { source; admitted_revision = state.revision; checkpoint_retentions = 0 }
      in
      reconcile available (entry :: acc) rest
  in
  (* Urgency order is a property of the pending list, not of the
     reprioritize/defer transitions alone: an [Immediate] arrival lands ahead
     of every [Normal] entry on arrival, and the sort is stable so arrival
     order is kept among entries of the same urgency. *)
  let pending_entries =
    Keeper_event_queue.sort_by_urgency pending
    |> Keeper_event_queue.to_list
    |> Keeper_event_queue.uniq_stimuli
    |> reconcile state.pending_entries []
  in
  { state with pending_entries }
;;

let with_revision revision state = { state with revision }

let transition_outbox_blocked state = state.transition_outbox <> []

(* #31597: a plain head-of-list scan never looks past the first ready
   [Normal]/[Immediate] entry, so a [Low] entry sitting further back never
   gets picked while the Keeper's own [Normal] backlog keeps refilling ahead
   of it — measured as a recurring schedule dispatching "succeeded" every
   hour for 16 days with zero Board output. [pending_entries] is still
   urgency-sorted on arrival (see [with_pending] above), so this full scan
   is over an already-short, already-ordered list; it picks the ready entry
   with the lowest *effective* urgency rank (aging applied), tie-broken by
   earliest [arrived_at] — which reduces to the old head-of-list behaviour
   whenever no entry has aged, since the list is still urgency-then-arrival
   ordered in that case. *)
let first_ready_entry ~now ~ready entries =
  let rank_of entry = Keeper_event_queue.effective_urgency_rank ~now entry.source in
  entries
  |> List.filter (fun entry -> ready entry.source)
  |> List.fold_left
       (fun best entry ->
          match best with
          | None -> Some entry
          | Some current ->
            let cmp = Int.compare (rank_of entry) (rank_of current) in
            if cmp < 0
            then Some entry
            else if cmp > 0
            then Some current
            else if entry.source.arrived_at < current.source.arrived_at
            then Some entry
            else Some current)
       None
;;

let peek_when ~now ~ready state =
  Option.map
    (fun entry -> entry.source)
    (first_ready_entry ~now ~ready state.pending_entries)
;;

let select_when ~now ~ready state = first_ready_entry ~now ~ready state.pending_entries

let validate_pending_selection
      ~(selection : pending_selection)
      state
  =
  let matching =
    state.pending_entries
    |> List.filter (fun entry ->
      Keeper_event_queue.stimulus_identity_equal
        selection.source
        entry.source)
  in
  match matching with
  | [ actual ] when actual = selection -> Ok ()
  | [ { source; _ } ] when source <> selection.source ->
    Error "event queue pending selection typed snapshot changed"
  | [ _ ] -> Error "event queue pending selection incarnation changed"
  | [] -> Error "event queue pending selection is no longer present"
  | _ :: _ :: _ ->
    Error "event queue pending selection is present more than once"
;;

let ack_pending ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    let pending_entries =
      List.filter (Fun.negate (( = ) selection)) state.pending_entries
    in
    Ok { state with pending_entries }
;;

(* A checkpoint-yield turn retains Connector_attention entries instead of
   acking them (see [Keeper_heartbeat_loop.batch_disposition_of_cycle_outcome]).
   That retention is a typed fact about delivery, so it is counted on the
   entry itself — durably, because the retention decision spans cycles and a
   server restart must not reset it. The returned selection carries the new
   count: validation is structural, so the caller's pre-bump snapshot is
   spent and must not be reused for a later ack or defer of this entry. *)
let note_checkpoint_retention ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    let retentions = selection.checkpoint_retentions + 1 in
    let updated = { selection with checkpoint_retentions = retentions } in
    let pending_entries =
      List.map
        (fun entry -> if entry = selection then updated else entry)
        state.pending_entries
    in
    Ok ({ state with pending_entries }, (updated, retentions))
;;

let reprioritize_pending
      ~(selection : pending_selection)
      ~urgency
      state
  =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    if selection.source.urgency = urgency
    then Ok (state, state.revision)
    else if Int64.equal state.revision Int64.max_int
    then Error "event queue revision exhausted"
    else
      let next_revision = Int64.succ state.revision in
      let updated =
        { source = { selection.source with urgency }
        ; admitted_revision = next_revision
        ; checkpoint_retentions = selection.checkpoint_retentions
        }
      in
      let pending_entries =
        List.map
          (fun entry -> if entry = selection then updated else entry)
          state.pending_entries
      in
      let state = { state with pending_entries } in
      let sorted_pending =
        pending state |> Keeper_event_queue.sort_by_urgency
      in
      Ok (with_pending sorted_pending state, next_revision)
;;

let defer_pending ~(selection : pending_selection) state =
  match validate_pending_selection ~selection state with
  | Error _ as error -> error
  | Ok () ->
    if Int64.equal state.revision Int64.max_int
    then Error "event queue revision exhausted"
    else
      let next_revision = Int64.succ state.revision in
      let deferred = { selection with admitted_revision = next_revision } in
      let same_urgency, other_urgency =
        state.pending_entries
        |> List.filter (Fun.negate (( = ) selection))
        |> List.partition (fun entry ->
          entry.source.urgency = selection.source.urgency)
      in
      let pending_entries = same_urgency @ [ deferred ] @ other_urgency in
      let state = { state with pending_entries } in
      let sorted_pending = state |> pending |> Keeper_event_queue.sort_by_urgency in
      Ok (with_pending sorted_pending state, next_revision)
;;

let ( let* ) = Result.bind

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

let transition_receipt_equal (left : transition_receipt) (right : transition_receipt) =
  String.equal left.transition_id right.transition_id
  && String.equal left.event_id right.event_id
  && Float.equal left.applied_at right.applied_at
  && left.transition = right.transition
;;

let validate_accepted_cancellation (cancellation : accepted_cancellation) =
  if String.equal (String.trim cancellation.source.post_id) ""
  then Error "accepted cancellation source post id must not be empty"
  else if Int64.compare cancellation.source_incarnation 0L < 0
  then Error "accepted cancellation source incarnation must not be negative"
  else if String.equal (String.trim cancellation.operator_operation_id) ""
  then Error "accepted cancellation operator operation id must not be empty"
  else if String.equal (String.trim cancellation.reason) ""
  then Error "accepted cancellation reason must not be empty"
  else Ok ()
;;

let validate_accepted_transfer (transfer : accepted_transfer) =
  if String.equal (String.trim transfer.source.post_id) ""
  then Error "accepted transfer source post id must not be empty"
  else if Int64.compare transfer.source_incarnation 0L < 0
  then Error "accepted transfer source incarnation must not be negative"
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
  | Keeper_event_queue.Hitl_resolved resolution -> Ok (Hitl_terminal resolution)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  (* Transferable receipts are the ones an operator can hand to another
     Keeper. A delegation answer belongs to the Keeper that asked; moving it
     would deliver an answer to someone who never asked. *)
  | Keeper_event_queue.Delegate_completed _
  (* Same reason: an answer belongs to the Keeper that asked the question. *)
  | Keeper_event_queue.Ask_answered _
  (* Same reason: an async composition's result belongs to the Keeper that
     submitted it. *)
  | Keeper_event_queue.Composition_completed _ ->
    Error "source event does not carry a typed terminal receipt"
;;

let validate_accepted_source_terminal
      (source_terminal : accepted_source_terminal)
  =
  if String.equal (String.trim source_terminal.source.post_id) ""
  then Error "source-terminal ACK source post id must not be empty"
  else if Int64.compare source_terminal.source_incarnation 0L < 0
  then Error "source-terminal ACK source incarnation must not be negative"
  else if String.equal (String.trim source_terminal.operator_operation_id) ""
  then Error "source-terminal ACK operation id must not be empty"
  else (
    match source_terminal.source_receipt with
    | Turn_completed | Turn_attempt_terminal _ -> Ok ()
    | (Fusion_terminal _ | Hitl_terminal _) as expected ->
      let* receipt = source_terminal_receipt_of_stimulus source_terminal.source in
      if receipt = expected
      then Ok ()
      else Error "source-terminal ACK receipt does not match source payload")
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
    let state = with_pending pending state in
    Ok
      ( { state with
          transition_outbox = [ { receipt; stimuli = [ source ] } ]
        }
      , Transition_applied receipt )
;;

let prior_disposition_by_operation_id operation_id state =
  let is_same_operation disposition =
    String.equal (durable_operation_id disposition) operation_id
  in
  match state.transition_outbox with
  | [ entry ]
    when String.equal
           (disposition_operation_id entry.receipt.transition)
           operation_id ->
    Some (Current_receipt entry.receipt)
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
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "accepted cancellation operation conflict: %s"
        cancellation.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "accepted cancellation operation conflict: %s"
         cancellation.operator_operation_id)
;;

let cancel_pending_accepted
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
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref cancellation.source)
        ~source_incarnation:cancellation.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot cancel pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
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
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "accepted transfer operation conflict: %s"
        transfer.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "accepted transfer operation conflict: %s"
         transfer.operator_operation_id)
;;

let transfer_pending_accepted
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
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref transfer.source)
        ~source_incarnation:transfer.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot transfer pending work while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
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
  | Some (Current_receipt receipt)
    when transition_equal receipt.transition requested ->
    Ok (Some receipt)
  | Some (Projected_witness witness) ->
    witness_receipt_for_exact_transition witness requested
    |> Result.map Option.some
    |> Result.map_error (fun _ ->
      Printf.sprintf
        "source-terminal ACK operation conflict: %s"
        source_terminal.operator_operation_id)
  | Some (Current_receipt _) ->
    Error
      (Printf.sprintf
         "source-terminal ACK operation conflict: %s"
         source_terminal.operator_operation_id)
;;

let turn_attempt_terminal_operation_id
      ~admitted_revision
      source
  =
  Printf.sprintf
    "turn-attempt-terminal:%Ld:%s"
    admitted_revision
    (source_snapshot_ref source)
;;

let ack_pending_source_terminal
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
      (* Identity and admission revision, not full structural equality:
         a live entry can carry checkpoint retentions the receipt cannot
         know, so exact-selection comparison would fail against a retained
         entry. *)
      resolve_pending_selection
        ~source_ref:(source_snapshot_ref source_terminal.source)
        ~source_incarnation:source_terminal.source_incarnation
        state
      |> Result.map (fun _ -> ())
    in
    let* () =
      if transition_outbox_blocked state
      then Error "event queue cannot ACK pending source while an outbox transition exists"
      else Ok ()
    in
    let matching, retained =
      Keeper_event_queue.to_list (pending state)
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

let turn_terminal_receipt_matches_replay left right =
  match left, right with
  | Turn_completed, Turn_completed
  | Turn_attempt_terminal _, Turn_attempt_terminal _ ->
    true
  | Fusion_terminal _, _
  | Hitl_terminal _, _
  | Turn_completed, _
  | Turn_attempt_terminal _, _ ->
    false
;;

let terminalize_pending_turn
      ~applied_at
      ~selection
      ~source_receipt
      state
  =
  let { source; admitted_revision } = selection in
  let operator_operation_id =
    turn_attempt_terminal_operation_id
      ~admitted_revision
      source
  in
  match prior_disposition_by_operation_id operator_operation_id state with
  | Some
      (Current_receipt
        ({ transition =
             Ack_source_terminal
               { source = prior_source
               ; source_receipt = prior_source_receipt
               ; _
               }
         ; _
         } as receipt))
    when prior_source = source
         && turn_terminal_receipt_matches_replay
              prior_source_receipt
              source_receipt ->
    Ok (state, Transition_already_applied receipt)
  | Some (Projected_witness witness)
    when String.equal witness.source_ref (source_snapshot_ref source)
         && Int64.equal witness.source_incarnation admitted_revision
         && (match witness.kind, source_receipt with
             | Projected_turn_completed, Turn_completed
             | Projected_turn_attempt_terminal, Turn_attempt_terminal _ -> true
             | Projected_fusion_terminal, Fusion_terminal _
             | Projected_hitl_terminal, Hitl_terminal _ ->
               String.equal witness.transition_ref (transition_ref (Ack_source_terminal
                 { source
                 ; source_incarnation = admitted_revision
                 ; operator_operation_id
                 ; source_receipt
                 }))
             | Projected_cancel _, _
             | Projected_transfer _, _
             | Projected_fusion_terminal, _
             | Projected_hitl_terminal, _
             | Projected_turn_completed, _
             | Projected_turn_attempt_terminal, _ -> false) ->
    let transition =
      Ack_source_terminal
        { source
        ; source_incarnation = admitted_revision
        ; operator_operation_id
        ; source_receipt
        }
    in
    let receipt =
      { transition_id = witness.transition_id
      ; event_id = witness.event_id
      ; applied_at = witness.applied_at
      ; transition
      }
    in
    Ok (state, Transition_already_applied receipt)
  | Some _ ->
    Error
      (Printf.sprintf
         "turn-attempt terminal operation conflict: %s"
         operator_operation_id)
  | None ->
    let* () = validate_pending_selection ~selection state in
    let source_terminal =
      { source
      ; source_incarnation = admitted_revision
      ; operator_operation_id
      ; source_receipt
      }
    in
    ack_pending_source_terminal
      ~applied_at
      ~source_terminal
      state
;;

let terminalize_pending_turn_attempt
      ~applied_at
      ~selection
      ~detail
      state
  =
  terminalize_pending_turn
    ~applied_at
    ~selection
    ~source_receipt:(Turn_attempt_terminal { detail })
    state
;;

let terminalize_pending_turn_completed
      ~applied_at
      ~selection
      state
  =
  terminalize_pending_turn
    ~applied_at
    ~selection
    ~source_receipt:Turn_completed
    state
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
         (fun disposition -> durable_matches_receipt disposition entry.receipt)
         (projected_dispositions state)
     with
     | Some _ -> Ok state
     | None ->
       (match entry.receipt.transition, entry.stimuli with
     | Cancel_accepted cancellation, [ source ] when source = cancellation.source ->
       restore_pending_transition entry state (fun state ->
         cancel_pending_accepted
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
    Keeper_event_queue.remove_by_post_id post_id (pending state)
  in
  Keeper_event_queue.uniq_stimuli removed, with_pending pending state
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

let int_field ~context name fields =
  let* value = required_field ~context name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s.%s must be an int" context name)
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

let transition_to_yojson = function
  | Cancel_accepted cancellation ->
    `Assoc
      [ "kind", `String "cancel_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson cancellation.source
      ; "source_incarnation", int64_json cancellation.source_incarnation
      ; "operator_operation_id", `String cancellation.operator_operation_id
      ; "reason", `String cancellation.reason
      ]
  | Transfer_accepted transfer ->
    `Assoc
      [ "kind", `String "transfer_accepted"
      ; "source", Keeper_event_queue.stimulus_to_yojson transfer.source
      ; "source_incarnation", int64_json transfer.source_incarnation
      ; "operator_operation_id", `String transfer.operator_operation_id
      ; "from_keeper", `String transfer.from_keeper
      ; "to_keeper", `String transfer.to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string transfer.target_trace_id)
      ]
  | Ack_source_terminal source_terminal ->
    let fields =
      [ "kind", `String "ack_source_terminal"
      ; "source", Keeper_event_queue.stimulus_to_yojson source_terminal.source
      ; "source_incarnation", int64_json source_terminal.source_incarnation
      ; "operator_operation_id", `String source_terminal.operator_operation_id
      ]
    in
    let receipt_fields =
      match source_terminal.source_receipt with
      | Fusion_terminal _ ->
        [ "source_receipt_kind", `String "fusion_terminal" ]
      | Hitl_terminal _ ->
        [ "source_receipt_kind", `String "hitl_terminal" ]
      | Turn_completed ->
        [ "source_receipt_kind", `String "turn_completed" ]
      | Turn_attempt_terminal { detail } ->
        [ "source_receipt_kind", `String "turn_attempt_terminal"
        ; "detail", `String detail
        ]
    in
    `Assoc (fields @ receipt_fields)
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
          ; "source_incarnation"
          ; "operator_operation_id"
          ; "reason"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* reason = string_field ~context "reason" fields in
    let cancellation =
      { source; source_incarnation; operator_operation_id; reason }
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
          ; "source_incarnation"
          ; "operator_operation_id"
          ; "from_keeper"
          ; "to_keeper"
          ; "target_trace_id"
          ]
        fields
    in
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let* target_trace_id_wire = string_field ~context "target_trace_id" fields in
    let* target_trace_id =
      Keeper_id.Trace_id.of_string target_trace_id_wire
      |> Result.map_error (fun detail ->
        Printf.sprintf "%s.target_trace_id is invalid: %s" context detail)
    in
    let transfer =
      { source
      ; source_incarnation
      ; operator_operation_id
      ; from_keeper
      ; to_keeper
      ; target_trace_id
      }
    in
    let* () = validate_accepted_transfer transfer in
    Ok (Transfer_accepted transfer)
  | "ack_source_terminal" ->
    let* source_json = required_field ~context "source" fields in
    let* source = Keeper_event_queue.stimulus_of_yojson source_json in
    let* source_incarnation = int64_field ~context "source_incarnation" fields in
    let* operator_operation_id =
      string_field ~context "operator_operation_id" fields
    in
    let* source_receipt_kind =
      string_field ~context "source_receipt_kind" fields
    in
    let common_fields =
      [ "kind"
      ; "source"
      ; "source_incarnation"
      ; "operator_operation_id"
      ; "source_receipt_kind"
      ]
    in
    let* source_receipt =
      match source_receipt_kind with
      | "turn_completed" ->
        let* () = exact_fields ~context ~expected:common_fields fields in
        Ok Turn_completed
      | "turn_attempt_terminal" ->
        let* () =
          exact_fields
            ~context
            ~expected:("detail" :: common_fields)
            fields
        in
        let* detail = string_field ~context "detail" fields in
        Ok (Turn_attempt_terminal { detail })
      | ("fusion_terminal" | "hitl_terminal") as expected_kind ->
        let* () = exact_fields ~context ~expected:common_fields fields in
        let* source_receipt = source_terminal_receipt_of_stimulus source in
        let* actual_kind =
          match source_receipt with
          | Fusion_terminal _ -> Ok "fusion_terminal"
          | Hitl_terminal _ -> Ok "hitl_terminal"
          | Turn_completed
          | Turn_attempt_terminal _ ->
            Error "source payload produced a non-intrinsic terminal receipt"
        in
        if String.equal expected_kind actual_kind
        then Ok source_receipt
        else Error "source-terminal receipt kind does not match source payload"
      | other ->
        Error (Printf.sprintf "unknown source-terminal receipt kind: %s" other)
    in
    let source_terminal =
      { source
      ; source_incarnation
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

let transition_receipt_to_yojson (receipt : transition_receipt) =
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

let is_sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value
;;

let projected_source_kind_to_string = function
  | Source_board_signal -> "board_signal"
  | Source_board_attention -> "board_attention"
  | Source_bootstrap -> "bootstrap"
  | Source_fusion_completed -> "fusion_completed"
  | Source_schedule_due -> "schedule_due"
  | Source_connector_attention -> "connector_attention"
  | Source_hitl_resolved -> "hitl_resolved"
  | Source_ask_answered -> "ask_answered"
  | Source_completion_authority_rejected -> "completion_authority_rejected"
  | Source_task_cancelled -> "task_cancelled"
  | Source_workspace_message -> "workspace_message"
  | Source_delegate_completed -> "keeper_delegate_completed"
  | Source_composition_completed -> "keeper_composition_completed"
;;

let source_kind_of_string = function
  | "board_signal" -> Ok Source_board_signal
  | "board_attention" -> Ok Source_board_attention
  | "bootstrap" -> Ok Source_bootstrap
  | "fusion_completed" -> Ok Source_fusion_completed
  | "schedule_due" -> Ok Source_schedule_due
  | "connector_attention" -> Ok Source_connector_attention
  | "hitl_resolved" -> Ok Source_hitl_resolved
  | "ask_answered" -> Ok Source_ask_answered
  | "completion_authority_rejected" -> Ok Source_completion_authority_rejected
  | "task_cancelled" -> Ok Source_task_cancelled
  | "workspace_message" -> Ok Source_workspace_message
  | "keeper_delegate_completed" -> Ok Source_delegate_completed
  | "keeper_composition_completed" -> Ok Source_composition_completed
  | other -> Error (Printf.sprintf "unknown projected source kind: %s" other)
;;

let projected_kind_to_yojson = function
  | Projected_cancel { reason_ref } ->
    `Assoc [ "kind", `String "cancel"; "reason_ref", `String reason_ref ]
  | Projected_transfer { from_keeper; to_keeper; target_trace_id } ->
    `Assoc
      [ "kind", `String "transfer"
      ; "from_keeper", `String from_keeper
      ; "to_keeper", `String to_keeper
      ; "target_trace_id", `String (Keeper_id.Trace_id.to_string target_trace_id)
      ]
  | Projected_fusion_terminal ->
    `Assoc [ "kind", `String "fusion_terminal" ]
  | Projected_hitl_terminal ->
    `Assoc [ "kind", `String "hitl_terminal" ]
  | Projected_turn_completed ->
    `Assoc [ "kind", `String "turn_completed" ]
  | Projected_turn_attempt_terminal ->
    `Assoc [ "kind", `String "turn_attempt_terminal" ]
;;

let projected_kind_of_yojson json =
  let context = "event queue projected disposition kind" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "cancel" ->
    let* () = exact_fields ~context ~expected:[ "kind"; "reason_ref" ] fields in
    let* reason_ref = string_field ~context "reason_ref" fields in
    if not (is_sha256 reason_ref)
    then Error "projected cancellation reason_ref must be lowercase sha256"
    else Ok (Projected_cancel { reason_ref })
  | "transfer" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "from_keeper"; "to_keeper"; "target_trace_id" ]
        fields
    in
    let* from_keeper = string_field ~context "from_keeper" fields in
    let* to_keeper = string_field ~context "to_keeper" fields in
    let* target_trace_id_wire = string_field ~context "target_trace_id" fields in
    let* target_trace_id =
      Keeper_id.Trace_id.of_string target_trace_id_wire
      |> Result.map_error (fun detail ->
        "projected transfer target_trace_id is invalid: " ^ detail)
    in
    if String.trim from_keeper = "" || String.trim to_keeper = ""
    then Error "projected transfer endpoints must not be empty"
    else if String.equal from_keeper to_keeper
    then Error "projected transfer endpoints must differ"
    else Ok (Projected_transfer { from_keeper; to_keeper; target_trace_id })
  | "fusion_terminal" | "hitl_terminal" | "turn_completed"
  | "turn_attempt_terminal" ->
    let* () = exact_fields ~context ~expected:[ "kind" ] fields in
    Ok
      (match kind with
       | "fusion_terminal" -> Projected_fusion_terminal
       | "hitl_terminal" -> Projected_hitl_terminal
       | "turn_completed" -> Projected_turn_completed
       | "turn_attempt_terminal" -> Projected_turn_attempt_terminal
       | _ -> assert false)
  | other -> Error (Printf.sprintf "unknown projected disposition kind: %s" other)
;;

let witness_to_yojson witness =
  `Assoc
    [ "transition_id", `String witness.transition_id
    ; "event_id", `String witness.event_id
    ; "applied_at_unix", `Float witness.applied_at
    ; "operator_operation_id", `String witness.operator_operation_id
    ; "transition_ref", `String witness.transition_ref
    ; "source_ref", `String witness.source_ref
    ; "post_id", `String witness.post_id
    ; "urgency", `String (Keeper_event_queue.urgency_to_string witness.urgency)
    ; "source_arrived_at", `Float witness.source_arrived_at
    ; ( "source_kind"
      , `String (projected_source_kind_to_string witness.source_kind) )
    ; "source_incarnation", int64_json witness.source_incarnation
    ; "disposition", projected_kind_to_yojson witness.kind
    ]
;;

let witness_of_yojson json =
  let context = "event queue projected disposition witness" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:
        [ "transition_id"
        ; "event_id"
        ; "applied_at_unix"
        ; "operator_operation_id"
        ; "transition_ref"
        ; "source_ref"
        ; "post_id"
        ; "urgency"
        ; "source_arrived_at"
        ; "source_kind"
        ; "source_incarnation"
        ; "disposition"
        ]
      fields
  in
  let* transition_id = string_field ~context "transition_id" fields in
  let* event_id = string_field ~context "event_id" fields in
  let* applied_at = float_field ~context "applied_at_unix" fields in
  let* operator_operation_id =
    string_field ~context "operator_operation_id" fields
  in
  let* transition_ref = string_field ~context "transition_ref" fields in
  let* source_ref = string_field ~context "source_ref" fields in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_raw = string_field ~context "urgency" fields in
  let* urgency = Keeper_event_queue.urgency_of_string urgency_raw in
  let* source_arrived_at = float_field ~context "source_arrived_at" fields in
  let* source_kind_raw = string_field ~context "source_kind" fields in
  let* source_kind = source_kind_of_string source_kind_raw in
  let* source_incarnation = int64_field ~context "source_incarnation" fields in
  let* disposition_json = required_field ~context "disposition" fields in
  let* kind = projected_kind_of_yojson disposition_json in
  let expected_transition_id =
    match kind with
    | Projected_cancel _ -> "pending-cancel:" ^ operator_operation_id
    | Projected_transfer _ -> "pending-transfer:" ^ operator_operation_id
    | Projected_fusion_terminal
    | Projected_hitl_terminal
    | Projected_turn_completed
    | Projected_turn_attempt_terminal ->
      "pending-source-terminal-ack:" ^ operator_operation_id
  in
  if not (Float.is_finite applied_at)
  then Error "projected disposition application time must be finite"
  else if not (Float.is_finite source_arrived_at)
  then Error "projected disposition source arrival time must be finite"
  else if Int64.compare source_incarnation 0L < 0
  then Error "projected disposition source incarnation must not be negative"
  else if String.trim operator_operation_id = ""
  then Error "projected disposition operation id must not be empty"
  else if String.trim post_id = ""
  then Error "projected disposition post id must not be empty"
  else if not (is_sha256 transition_ref && is_sha256 source_ref)
  then Error "projected disposition references must be lowercase sha256"
  else if not (String.equal transition_id expected_transition_id)
  then Error "projected disposition transition id mismatch"
  else if not (String.equal event_id (event_id_of_transition transition_id))
  then Error "projected disposition event id mismatch"
  else if
    match kind, source_kind with
    | Projected_fusion_terminal, Source_fusion_completed
    | Projected_hitl_terminal, Source_hitl_resolved -> false
    | Projected_fusion_terminal, _
    | Projected_hitl_terminal, _ -> true
    | Projected_cancel _, _
    | Projected_transfer _, _
    | Projected_turn_completed, _
    | Projected_turn_attempt_terminal, _ -> false
  then Error "projected intrinsic terminal kind conflicts with source kind"
  else
    Ok
      { transition_id
      ; event_id
      ; applied_at
      ; operator_operation_id
      ; transition_ref
      ; source_ref
      ; post_id
      ; urgency
      ; source_arrived_at
      ; source_kind
      ; source_incarnation
      ; kind
      }
;;

let durable_disposition_to_yojson = function
  | Current_receipt receipt ->
    `Assoc
      [ "storage", `String "full_receipt"
      ; "receipt", transition_receipt_to_yojson receipt
      ]
  | Projected_witness witness ->
    `Assoc
      [ "storage", `String "compact_witness"
      ; "witness", witness_to_yojson witness
      ]
;;

let durable_disposition_of_yojson json =
  let context = "event queue projected disposition" in
  let* fields = assoc_fields ~context json in
  let* storage = string_field ~context "storage" fields in
  match storage with
  | "full_receipt" ->
    Error "projected history must use a compact witness"
  | "compact_witness" ->
    let* () = exact_fields ~context ~expected:[ "storage"; "witness" ] fields in
    let* witness_json = required_field ~context "witness" fields in
    witness_of_yojson witness_json |> Result.map (fun w -> Projected_witness w)
  | other -> Error (Printf.sprintf "unknown projected disposition storage: %s" other)
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

let pending_entry_to_yojson entry =
  `Assoc
    [ "source", Keeper_event_queue.stimulus_to_yojson entry.source
    ; "admitted_revision", int64_json entry.admitted_revision
    ; "checkpoint_retentions", `Int entry.checkpoint_retentions
    ]
;;

let pending_entry_of_yojson json =
  let context = "event queue pending entry" in
  let* fields = assoc_fields ~context json in
  let* () =
    exact_fields
      ~context
      ~expected:[ "source"; "admitted_revision"; "checkpoint_retentions" ]
      fields
  in
  let* source_json = required_field ~context "source" fields in
  let* source = Keeper_event_queue.stimulus_of_yojson source_json in
  let* admitted_revision =
    int64_field ~context "admitted_revision" fields
  in
  let* checkpoint_retentions =
    int_field ~context "checkpoint_retentions" fields
  in
  if Int64.compare admitted_revision 0L < 0
  then Error "event queue pending admission revision must not be negative"
  else if checkpoint_retentions < 0 then
    Error "event queue pending checkpoint retentions must not be negative"
  else Ok { source; admitted_revision; checkpoint_retentions }
;;

let to_yojson state =
  `Assoc
    [ "schema", `String schema
    ; "revision", int64_json state.revision
    ; ( "pending"
      , `List (List.map pending_entry_to_yojson state.pending_entries) )
    ; ( "last_transition"
      , match state.last_transition with
        | None -> `Null
        | Some receipt -> transition_receipt_to_yojson receipt )
    ; ( "projected_dispositions"
      , `List
          (List.map
             durable_disposition_to_yojson
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

module String_set = Set.Make (String)

let duplicate_by key values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      let key = key value in
      if String_set.mem key seen
      then Some key
      else loop (String_set.add key seen) rest
  in
  loop String_set.empty values
;;

let pending_identity_is_duplicated (entries : pending_selection list) =
  let rec loop seen = function
    | [] -> false
    | entry :: rest ->
      if
        List.exists
          (fun prior ->
             Keeper_event_queue.stimulus_identity_equal
               prior.source
               entry.source)
          seen
      then true
      else loop (entry :: seen) rest
  in
  loop [] entries
;;

let validate_state state =
  if Int64.compare state.revision 0L < 0
  then Error "event queue revision must not be negative"
  else if
    List.exists
      (fun entry ->
         Int64.compare entry.admitted_revision 0L < 0
         || Int64.compare entry.admitted_revision state.revision > 0)
      state.pending_entries
  then Error "event queue pending admission revision is outside the durable state"
  else if pending_identity_is_duplicated state.pending_entries
  then Error "event queue pending source identity is duplicated"
  else if List.length state.transition_outbox > 1
  then Error "event queue state must contain at most one unprojected transition"
  else if
    match state.transition_outbox with
    | [ entry ] ->
      List.exists
        (fun disposition ->
           String.equal
             (durable_transition_id disposition)
             entry.receipt.transition_id)
        (projected_dispositions state)
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
          durable_transition_id
          (projected_dispositions state)
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
        durable_operation_id
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
    Ok state
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
  let* pending_entries =
    list_field ~context "pending" pending_entry_of_yojson fields
  in
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
      durable_disposition_of_yojson
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
    ; pending_entries
    ; last_transition
    ; projected_dispositions
    ; transition_outbox
    ; accepted_transfer_projections
    }
;;
