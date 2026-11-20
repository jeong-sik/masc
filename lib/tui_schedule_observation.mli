(** Read-only evidence for the latest occurrence of a scheduled Keeper wake.
    Dispatch acceptance, a turn boundary and durable completion are distinct.
    No timer, wake, acknowledgement or other mutation is performed here. *)

(** Why the evidence does not settle an occurrence's stage. Facts only: the
    TUI chooses the mark and the words. *)
type undetermined =
  | Receipt_not_seen
      (** The wake was enqueued, and no evidence yet shows the Keeper saw it. *)
  | Stimulus_absent
      (** The dispatch receipt names no exact stimulus, so no reaction can be
          bound to this occurrence. *)
  | Receipt_unsupported of string
      (** The dispatch receipt is a kind this build's decoder refuses; the
          decoder's reason. *)
  | Status_unsupported of string
      (** The wake's [status] is not one this build reads; the status as
          written. *)
  | Reaction_unreadable
      (** The reaction ledger's projection could not be read or bound to this
          wake: a read error, a quarantined record, an invalid or missing
          stimulus id, or a receipt it does not recognize. *)
  | Queue_unreadable
      (** The queue's projection could not be read: a read error, invalid
          evidence, or a receipt it does not recognize. *)
  | Consumption_conflict
      (** The reaction ledger records conflicting terminal evidence: an
          acknowledgement and a cancellation of one wake. *)
  | Terminal_disagreement
      (** The queue's terminal outcome disagrees with the reaction ledger. *)
  | Queue_still_holds
      (** The queue still holds a wake the reaction ledger says was consumed
          or cancelled. *)
  | Reaction_stage_unexpected
      (** The reaction ledger reports a stage a reaction cannot reach. *)

type stage =
  | No_occurrence
  | Dispatching
  | Dispatch_failed of string option
  | Queued
  | Queued_at of string
  | Missing
  | Turn_started
  | Turn_ended of Keeper_reaction_ledger.Turn_disposition.t
      (** The turn the wake started finished, with the turn's own disposition. *)
  | Consumed
  | Completed
  | Receipt_is_the_record
      (** Dispatch finished the occurrence in one step: a delivered
          tool-result receipt or a handed-over Lane action. That receipt is
          its whole record; no queue or reaction evidence follows it
          ([Schedule_occurrence_consumption.Receipt_is_the_record]). For a
          Lane action it says the action was handed to its worker, not that
          the action succeeded; a failure inside the worker does not show
          here. *)
  | Cancelled of string option
  | Settling of string
      (** The terminal result is recorded but not yet projected into the
          named Keeper's queue: the Keeper the occurrence resolved to. *)
  | Transferring of { owner : string; target : string }
      (** [owner] handed the occurrence to [target]; the transfer is not yet
          projected into [target]'s queue. *)
  | Undetermined of undetermined

type t =
  { stage : stage
  ; due_at_iso : string option
  }

val decode : Yojson.Safe.t -> (t, string) result
(** Decode a dashboard schedule row. Queue/reaction evidence must agree with
    the row's instance, schedule and exact dispatch stimulus. Queue evidence
    also binds the wake's due time and payload digest. A queue or reaction
    [projection_status] outside [Schedule_contract_values] returns [Error].
    The dispatch receipt in [last_wake.detail] is read with
    [Schedule_dispatch_receipt.dispatch_receipt_of_detail]. A receipt that
    decoder refuses is [Undetermined] for its row alone, so one newer receipt kind
    does not drop the page; an identity mismatch stays [Error].
    A supported receipt without an exact stimulus stays
    [Undetermined] after checking the schedule and Keeper target; malformed or
    contradictory identities still return [Error].
    [due_at_iso] belongs to the last wake, never the next scheduled firing. *)

val needs_attention : stage -> bool
(** Pending execution or uncertain/failed delivery, rather than a finished
    historical occurrence. This never implies operator action is required. *)
