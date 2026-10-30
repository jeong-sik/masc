
module Event_id_set = Set.Make (String)
type row_quarantine_reason = Invalid_row | Wrong_keeper
type reaction_kind = Turn_started | Turn_finished | Event_queue_ack | Event_queue_cancelled
type metadata = { event_id : string; recorded_at : float }
type current_row = Current_stimulus of { metadata : metadata }
  | Current_reaction of { metadata : metadata; reaction_kind : reaction_kind }
type row = Good of current_row | Bad of row_quarantine_reason
let decode_current_row ~keeper_name:_ = function Good row -> Ok row | Bad error -> Error error

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; turn_finished_seen : bool
  ; event_queue_ack_seen : bool
  ; event_queue_cancelled_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; turn_finished_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; event_queue_cancelled_recorded_at : float option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  ; quarantined_record_count : int
  }

type event_queue_reaction_evidence_outcome =
  | Evidence_complete of event_queue_reaction_evidence
  | Evidence_quarantined of
      { evidence : event_queue_reaction_evidence
      ; first_reason : row_quarantine_reason
      }


let max_recorded_at current candidate =
  match current, candidate with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (Float.max left right)
;;

type event_queue_reaction_evidence_accumulator =
  { mutable stimulus_recorded_at : float option
  ; mutable turn_started_recorded_at : float option
  ; mutable turn_finished_recorded_at : float option
  ; mutable event_queue_ack_recorded_at : float option
  ; mutable event_queue_cancelled_recorded_at : float option
  ; mutable latest_recorded_at : float option
  ; mutable matched_record_count : int
  ; mutable quarantined_record_count : int
  ; mutable first_matching_quarantine_reason : row_quarantine_reason option
  ; mutable seen_event_ids : Event_id_set.t
  }

let empty_event_queue_reaction_evidence_accumulator () =
  { stimulus_recorded_at = None
  ; turn_started_recorded_at = None
  ; turn_finished_recorded_at = None
  ; event_queue_ack_recorded_at = None
  ; event_queue_cancelled_recorded_at = None
  ; latest_recorded_at = None
  ; matched_record_count = 0
  ; quarantined_record_count = 0
  ; first_matching_quarantine_reason = None
  ; seen_event_ids = Event_id_set.empty
  }
;;

let note_event_queue_reaction_evidence_row ~keeper_name accumulator row =
  match decode_current_row ~keeper_name row with
  | Error reason ->
    accumulator.quarantined_record_count
      <- accumulator.quarantined_record_count + 1;
    (match accumulator.first_matching_quarantine_reason with
     | Some _ -> ()
     | None -> accumulator.first_matching_quarantine_reason <- Some reason)
  | Ok current_row ->
    let metadata =
      match current_row with
      | Current_stimulus { metadata; _ }
      | Current_reaction { metadata; _ } -> metadata
    in
    if Event_id_set.mem metadata.event_id accumulator.seen_event_ids
    then ()
    else (
      (* Only a decoded record owns an event identity. A damaged append must
         remain visible without shadowing a later valid replay of that event. *)
      accumulator.seen_event_ids
        <- Event_id_set.add metadata.event_id accumulator.seen_event_ids;
      accumulator.matched_record_count <- accumulator.matched_record_count + 1;
      let recorded_at = Some metadata.recorded_at in
      accumulator.latest_recorded_at
        <- max_recorded_at accumulator.latest_recorded_at recorded_at;
      (match current_row with
       | Current_stimulus _ ->
         accumulator.stimulus_recorded_at
           <- max_recorded_at accumulator.stimulus_recorded_at recorded_at
       | Current_reaction { reaction_kind = Turn_started; _ } ->
         accumulator.turn_started_recorded_at
           <- max_recorded_at accumulator.turn_started_recorded_at recorded_at
       | Current_reaction { reaction_kind = Turn_finished; _ } ->
         accumulator.turn_finished_recorded_at
           <- max_recorded_at accumulator.turn_finished_recorded_at recorded_at
       | Current_reaction { reaction_kind = Event_queue_ack; _ } ->
         accumulator.event_queue_ack_recorded_at
           <- max_recorded_at accumulator.event_queue_ack_recorded_at recorded_at
       | Current_reaction { reaction_kind = Event_queue_cancelled; _ } ->
         accumulator.event_queue_cancelled_recorded_at
           <- max_recorded_at
                accumulator.event_queue_cancelled_recorded_at
                recorded_at))
;;

let event_queue_reaction_evidence_of_accumulator
      ~keeper_name
      ~stimulus_id
      accumulator
  =
  let evidence =
    { keeper_name
    ; stimulus_id
    ; stimulus_seen = Option.is_some accumulator.stimulus_recorded_at
    ; turn_started_seen = Option.is_some accumulator.turn_started_recorded_at
    ; turn_finished_seen = Option.is_some accumulator.turn_finished_recorded_at
    ; event_queue_ack_seen = Option.is_some accumulator.event_queue_ack_recorded_at
    ; event_queue_cancelled_seen = Option.is_some accumulator.event_queue_cancelled_recorded_at
    ; stimulus_recorded_at = accumulator.stimulus_recorded_at
    ; turn_started_recorded_at = accumulator.turn_started_recorded_at
    ; turn_finished_recorded_at = accumulator.turn_finished_recorded_at
    ; event_queue_ack_recorded_at = accumulator.event_queue_ack_recorded_at
    ; event_queue_cancelled_recorded_at =
        accumulator.event_queue_cancelled_recorded_at
    ; latest_recorded_at = accumulator.latest_recorded_at
    ; matched_record_count = accumulator.matched_record_count
    ; quarantined_record_count = accumulator.quarantined_record_count
    }
  in
  match accumulator.first_matching_quarantine_reason with
  | Some first_reason -> Evidence_quarantined { evidence; first_reason }
  | None -> Evidence_complete evidence
;;
