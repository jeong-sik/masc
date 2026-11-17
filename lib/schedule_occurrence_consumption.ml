(* TEL-OK: a read projection. [read] reads one Keeper's reaction ledger and
   returns its failure as a typed value; it writes nothing. *)

type reaction_reading =
  | Conflicting_terminal_evidence
  | Terminal_cancelled
  | Consumed_ack
  | Turn_finished
  | Turn_started
  | Stimulus_seen
  | No_reaction_recorded

let reaction_reading_of_evidence
  (evidence : Keeper_reaction_ledger.event_queue_reaction_evidence)
  =
  match evidence.event_queue_ack_seen, evidence.event_queue_cancelled_seen with
  | true, true -> Conflicting_terminal_evidence
  | false, true -> Terminal_cancelled
  | true, false -> Consumed_ack
  | false, false ->
    (* Finished outranks started: both rows are written for the same
       stimulus, and the later one is the more complete reading of what
       happened. *)
    if Option.is_some evidence.turn_finished
    then Turn_finished
    else if evidence.turn_started_seen
    then Turn_started
    else if evidence.stimulus_seen
    then Stimulus_seen
    else No_reaction_recorded
;;

let reaction_reading_to_status = function
  | Conflicting_terminal_evidence ->
    Schedule_contract_values.Reaction_conflicting_terminal_evidence
  | Terminal_cancelled -> Schedule_contract_values.Reaction_matched_terminal_cancelled
  | Consumed_ack -> Schedule_contract_values.Reaction_matched_consumed_ack
  | Turn_finished -> Schedule_contract_values.Reaction_matched_turn_finished
  | Turn_started -> Schedule_contract_values.Reaction_matched_turn_started
  | Stimulus_seen -> Schedule_contract_values.Reaction_matched_stimulus
  | No_reaction_recorded -> Schedule_contract_values.Reaction_not_found
;;

let reaction_reading_to_string reading =
  Schedule_contract_values.reaction_projection_status_to_string
    (reaction_reading_to_status reading)
;;

type keeper_occurrence =
  { keeper_name : string
  ; stimulus_id : string
  }

type t =
  | No_dispatch_receipt
  | Unrecognized_receipt of string
  | Receipt_is_the_record
  | Missing_stimulus_id of { keeper_name : string }
  | Reaction_read_failed of
      { occurrence : keeper_occurrence
      ; error : Keeper_reaction_ledger.event_queue_reaction_evidence_error
      }
  | Reaction_observed of
      { occurrence : keeper_occurrence
      ; reading : reaction_reading
      ; evidence : Keeper_reaction_ledger.event_queue_reaction_evidence
      }
  | Reaction_quarantined of
      { occurrence : keeper_occurrence
      ; evidence : Keeper_reaction_ledger.event_queue_reaction_evidence
      ; first_reason : Keeper_reaction_ledger.row_quarantine_reason
      }

let of_receipt ~read_evidence (wake : Schedule_domain.wake_record) =
  match wake.detail with
  | None -> No_dispatch_receipt
  | Some detail ->
    (match Schedule_dispatch_receipt.dispatch_receipt_of_detail detail with
     | Error reason -> Unrecognized_receipt reason
     | Ok
         ( Schedule_dispatch_receipt.Lane_act_handed_over _
         | Schedule_dispatch_receipt.Keeper_receipt_delivered _ ) ->
       Receipt_is_the_record
     | Ok (Schedule_dispatch_receipt.Keeper_wake_enqueued { keeper_name; stimulus_id; _ })
       ->
       (match stimulus_id with
        | None -> Missing_stimulus_id { keeper_name }
        | Some stimulus_id ->
          let occurrence = { keeper_name; stimulus_id } in
          (match read_evidence ~keeper_name ~stimulus_id with
           | Error error -> Reaction_read_failed { occurrence; error }
           | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
             Reaction_observed
               { occurrence
               ; reading = reaction_reading_of_evidence evidence
               ; evidence
               }
           | Ok (Keeper_reaction_ledger.Evidence_quarantined { evidence; first_reason })
             ->
             Reaction_quarantined { occurrence; evidence; first_reason })))
;;

let read ~base_path wake =
  of_receipt
    ~read_evidence:(Keeper_reaction_ledger.event_queue_reaction_evidence_result ~base_path)
    wake
;;

let time_fields name value =
  match value with
  | None -> [ name, `Null; name ^ "_iso", `Null ]
  | Some ts ->
    [ name, `Float ts; name ^ "_iso", `String (Masc_domain.iso8601_of_unix_seconds ts) ]
;;

let evidence_fields (evidence : Keeper_reaction_ledger.event_queue_reaction_evidence) =
  [ "stimulus_seen", `Bool evidence.stimulus_seen
  ; "turn_started_seen", `Bool evidence.turn_started_seen
  ; "turn_finished_seen", `Bool (Option.is_some evidence.turn_finished)
  ; "event_queue_ack_seen", `Bool evidence.event_queue_ack_seen
  ; "event_queue_cancelled_seen", `Bool evidence.event_queue_cancelled_seen
  ; "matched_record_count", `Int evidence.matched_record_count
  ; "quarantined_record_count", `Int evidence.quarantined_record_count
  ]
  @ time_fields "turn_finished_recorded_at" evidence.turn_finished_recorded_at
  @ time_fields "event_queue_ack_recorded_at" evidence.event_queue_ack_recorded_at
  @ time_fields
      "event_queue_cancelled_recorded_at"
      evidence.event_queue_cancelled_recorded_at
  @ time_fields "latest_recorded_at" evidence.latest_recorded_at
;;

let occurrence_fields { keeper_name; stimulus_id } =
  [ "source", `String "keeper_reaction_ledger"
  ; "keeper_name", `String keeper_name
  ; "stimulus_id", `String stimulus_id
  ]
;;

let to_yojson = function
  | No_dispatch_receipt -> `Assoc [ "status", `String "no_dispatch_receipt" ]
  | Unrecognized_receipt reason ->
    `Assoc [ "status", `String "unrecognized_receipt"; "reason", `String reason ]
  | Receipt_is_the_record -> `Assoc [ "status", `String "receipt_is_the_record" ]
  | Missing_stimulus_id { keeper_name } ->
    `Assoc
      [ "status", `String "missing_stimulus_id"; "keeper_name", `String keeper_name ]
  | Reaction_read_failed { occurrence; error } ->
    let status =
      match error with
      | Keeper_reaction_ledger.Evidence_invalid_stimulus_id -> "invalid_stimulus_id"
      | Keeper_reaction_ledger.Evidence_read_error _ -> "read_error"
    in
    `Assoc
      ((("status", `String status) :: occurrence_fields occurrence)
       @ [ ( "reason"
           , `String
               (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
                  error) )
         ])
  | Reaction_observed { occurrence; reading; evidence } ->
    `Assoc
      ((("status", `String (reaction_reading_to_string reading))
        :: occurrence_fields occurrence)
       @ evidence_fields evidence)
  | Reaction_quarantined { occurrence; evidence; first_reason } ->
    `Assoc
      ((("status", `String "quarantined") :: occurrence_fields occurrence)
       @ [ ( "reason"
           , `String (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)
           )
         ]
       @ evidence_fields evidence)
;;
