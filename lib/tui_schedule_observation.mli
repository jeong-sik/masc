(** Read-only evidence for the latest occurrence of a scheduled Keeper wake.
    Dispatch acceptance, a turn boundary and durable completion are distinct.
    No timer, wake, acknowledgement or other mutation is performed here. *)
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
          ([Schedule_occurrence_consumption.Receipt_is_the_record]). *)
  | Cancelled of string option
  | Settling of string
      (** The terminal result is recorded but not yet projected into the
          named Keeper's queue: the Keeper the occurrence resolved to. *)
  | Transferring of { owner : string; target : string }
      (** [owner] handed the occurrence to [target]; the transfer is not yet
          projected into [target]'s queue. *)
  | Unknown of string

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
    [Schedule_dispatch_receipt.dispatch_receipt_of_detail], so a kind that
    decoder refuses returns [Error] as well.
    A supported receipt without an exact stimulus stays
    [Unknown] after checking the schedule and Keeper target; malformed or
    contradictory identities still return [Error].
    [due_at_iso] belongs to the last wake, never the next scheduled firing. *)

val needs_attention : stage -> bool
(** Pending execution or uncertain/failed delivery, rather than a finished
    historical occurrence. This never implies operator action is required. *)
