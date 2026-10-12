include Keeper_event_queue_state_core

let projected_source_kind_to_string = Keeper_event_queue_state_wire.projected_source_kind_to_string
let durable_disposition_to_yojson = Keeper_event_queue_state_wire.durable_disposition_to_yojson
let durable_disposition_of_yojson = Keeper_event_queue_state_wire.durable_disposition_of_yojson
let transition_receipt_to_yojson = Keeper_event_queue_state_wire.transition_receipt_to_yojson
let transition_receipt_of_yojson = Keeper_event_queue_state_wire.transition_receipt_of_yojson
let outbox_entry_to_yojson = Keeper_event_queue_state_wire.outbox_entry_to_yojson
let outbox_entry_of_yojson = Keeper_event_queue_state_wire.outbox_entry_of_yojson
let to_yojson = Keeper_event_queue_state_wire.to_yojson
let of_yojson = Keeper_event_queue_state_wire.of_yojson
let schema = Keeper_event_queue_state_wire.schema

type occurrence_terminal_evidence =
  | Terminal_evidence_pending of string
  | Terminal_evidence_recorded

type schedule_occurrence_state =
  | Occurrence_pending
  | Occurrence_transfer_projecting_to of string
  | Occurrence_transferred_to of string
  | Occurrence_completed of occurrence_terminal_evidence
  | Occurrence_failed of string * occurrence_terminal_evidence
  | Occurrence_cancelled of string * occurrence_terminal_evidence

type schedule_occurrence_source =
  | Full_source of Keeper_event_queue.stimulus
  | Compact_source of
      { post_id : string
      ; urgency : Keeper_event_queue.urgency
      ; arrived_at : float
      ; source_ref : string
      }

type schedule_occurrence =
  { occurrence_id : string
  ; occurrence_source : schedule_occurrence_source
  ; occurrence_incarnation : int64
  ; occurrence_state : schedule_occurrence_state
  }

let is_schedule_source source =
  Option.is_some (Keeper_event_queue.scheduled_wake source)
;;

let schedule_occurrence_of_receipt ~projecting (receipt : transition_receipt) =
  let evidence =
    if projecting
    then Terminal_evidence_pending receipt.transition_id
    else Terminal_evidence_recorded
  in
  let source, source_incarnation, occurrence_state =
    match receipt.transition with
    | Cancel_accepted cancellation ->
      ( cancellation.source
      , cancellation.source_incarnation
      , Occurrence_cancelled (cancellation.reason, evidence) )
    | Transfer_accepted transfer ->
      ( transfer.source
      , transfer.source_incarnation
      , (if projecting
         then Occurrence_transfer_projecting_to transfer.to_keeper
         else Occurrence_transferred_to transfer.to_keeper) )
    | Ack_source_terminal terminal ->
      ( terminal.source
      , terminal.source_incarnation
      , (match terminal.source_receipt with
         | Turn_attempt_terminal { detail } -> Occurrence_failed (detail, evidence)
         | Fusion_terminal _ | Hitl_terminal _ | Turn_completed ->
           Occurrence_completed evidence) )
  in
  { occurrence_id = source.Keeper_event_queue.post_id
  ; occurrence_source = Full_source source
  ; occurrence_incarnation = source_incarnation
  ; occurrence_state
  }
;;

let schedule_occurrence_of_witness (witness : projected_disposition_witness) =
  let occurrence () =
    let occurrence_state =
      match witness.kind with
      | Projected_cancel _ ->
        Occurrence_cancelled ("projected cancellation", Terminal_evidence_recorded)
      | Projected_transfer { to_keeper; _ } -> Occurrence_transferred_to to_keeper
      | Projected_turn_attempt_terminal ->
        Occurrence_failed
          ("projected turn attempt terminal", Terminal_evidence_recorded)
      | Projected_turn_completed
      | Projected_fusion_terminal
      | Projected_hitl_terminal -> Occurrence_completed Terminal_evidence_recorded
    in
    { occurrence_id = witness.post_id
    ; occurrence_source =
        Compact_source
          { post_id = witness.post_id
          ; urgency = witness.urgency
          ; arrived_at = witness.source_arrived_at
          ; source_ref = witness.source_ref
          }
    ; occurrence_incarnation = witness.source_incarnation
    ; occurrence_state
    }
  in
  match witness.source_kind with
  | Source_schedule_due -> Some (occurrence ())
  | Source_board_signal
  | Source_board_attention
  | Source_bootstrap
  | Source_fusion_completed
  | Source_connector_attention
  | Source_hitl_resolved
  | Source_ask_answered
  | Source_completion_authority_rejected
  | Source_task_outcome
  | Source_task_cancelled
  | Source_workspace_message
  | Source_delegate_completed
  | Source_composition_completed -> None
;;

let schedule_occurrences state =
  let pending =
    List.filter_map
      (fun (selection : pending_selection) ->
         if is_schedule_source selection.source
         then
           Some
             { occurrence_id = selection.source.Keeper_event_queue.post_id
             ; occurrence_source = Full_source selection.source
             ; occurrence_incarnation = selection.admitted_revision
             ; occurrence_state = Occurrence_pending
             }
         else None)
      state.pending_entries
  in
  let of_receipt ~projecting (receipt : transition_receipt) =
    if is_schedule_source (transition_source receipt.transition)
    then Some (schedule_occurrence_of_receipt ~projecting receipt)
    else None
  in
  let outbox =
    List.filter_map
      (fun (entry : outbox_entry) -> of_receipt ~projecting:true entry.receipt)
      state.transition_outbox
  in
  let projected =
    List.filter_map
      (function
        | Current_receipt receipt -> of_receipt ~projecting:false receipt
        | Projected_witness witness -> schedule_occurrence_of_witness witness)
      (projected_dispositions state)
  in
  pending @ outbox @ projected
;;
