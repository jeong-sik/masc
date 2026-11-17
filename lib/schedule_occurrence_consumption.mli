(** What the target Keeper has done with one dispatched schedule occurrence,
    read from its reaction ledger at the time of the call.

    The wake record's dispatch receipt ({!Schedule_dispatch_receipt}) is
    written once, when dispatch accepts the occurrence. Its
    [occurrence_status] is therefore [awaiting_ack] for every occurrence the
    Keeper had not consumed at that instant, and stays so after the Keeper
    consumes it (#36054). This module reads the later facts instead. The
    dashboard schedule projection and [masc_schedule_get] classify the same
    ledger evidence through {!reaction_reading_of_evidence}. *)

(** The furthest point the reaction ledger shows for the occurrence. When
    both an ACK and an accepted cancellation are recorded the reading is
    [Conflicting_terminal_evidence], not either one. *)
type reaction_reading =
  | Conflicting_terminal_evidence
  | Terminal_cancelled
  | Consumed_ack
  | Turn_finished
  | Turn_started
  | Stimulus_seen
  | No_reaction_recorded

val reaction_reading_of_evidence :
  Keeper_reaction_ledger.event_queue_reaction_evidence -> reaction_reading

val reaction_reading_to_status :
  reaction_reading -> Schedule_contract_values.reaction_projection_status
(** The dashboard's [keeper_reaction_evidence.projection_status] value for a
    reading. Every reading maps to one of the seven [Reaction_matched_*],
    [Reaction_conflicting_terminal_evidence] or [Reaction_not_found] statuses. *)

val reaction_reading_to_string : reaction_reading -> string
(** [Schedule_contract_values.reaction_projection_status_to_string] of
    {!reaction_reading_to_status}: [conflicting_terminal_evidence],
    [matched_terminal_cancelled], [matched_consumed_ack],
    [matched_turn_finished], [matched_turn_started], [matched_stimulus],
    [not_found]. *)

type keeper_occurrence =
  { keeper_name : string
  ; stimulus_id : string
  }

type t =
  | No_dispatch_receipt
      (** The wake record carries no receipt: dispatch has not accepted it. *)
  | Unrecognized_receipt of string
      (** The stored receipt does not decode. The string is the decode error. *)
  | Receipt_is_the_record
      (** A Lane action hand-over or a Keeper receipt delivery. No Keeper
          queue consumes it, so the receipt is the whole record. *)
  | Missing_stimulus_id of { keeper_name : string }
      (** A Keeper wake receipt with no exact stimulus identity, so no ledger
          row can be attributed to it. *)
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
      (** A ledger row names this occurrence but does not decode as a
          current row. The reading is withheld rather than guessed. *)

val of_receipt :
  read_evidence:
    (keeper_name:string ->
     stimulus_id:string ->
     ( Keeper_reaction_ledger.event_queue_reaction_evidence_outcome
     , Keeper_reaction_ledger.event_queue_reaction_evidence_error )
     result) ->
  Schedule_domain.wake_record ->
  t
(** Decodes the wake's receipt and, for a Keeper wake with a stimulus
    identity, asks [read_evidence] once for that occurrence. *)

val read : base_path:string -> Schedule_domain.wake_record -> t
(** [of_receipt] over
    {!Keeper_reaction_ledger.event_queue_reaction_evidence_result}. Reads the
    target Keeper's reaction ledger from disk. *)

val to_yojson : t -> Yojson.Safe.t
(** Closed [status]: [no_dispatch_receipt], [unrecognized_receipt],
    [receipt_is_the_record], [missing_stimulus_id], [invalid_stimulus_id],
    [read_error], [quarantined], or one {!reaction_reading_to_string} word.
    Observed and quarantined readings carry the ledger booleans and the
    recorded times. *)
