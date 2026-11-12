(** The schedule a receipt wait can name instead of a background run.

    A model names a schedule by its [schedule_id], the one [masc_schedule_create]
    returns. The wait is recorded under the schedule's
    {!Schedule_supported_kinds.receipt_key} instead, the [call_id] of the receipt
    a Keeper wake of delivery [receipt] writes ({!Keeper_schedule_receipt}). The
    schedule id cannot be the wait's id: a Keeper may pick it, so it can equal
    an Execute request id, or name a schedule created again after the first was
    pruned while the first one's receipt is still in the outbox. An edit of a
    schedule that has not ended and the settling of a run watch keep the key.
    This module reads the schedule row for either name. The row is the only
    record of the schedule: the wait keeps none. *)

type receipt_state =
  | Waiting
      (** Not ended: the wake will still write its receipt. *)
  | Ended
      (** Delivered, failed, cancelled or expired. It may or may not have
          written its receipt. *)

type schedule_row =
  | Row_receipt of
      { receipt_key : Schedule_supported_kinds.receipt_key
      ; state : receipt_state
      }
      (** A wake of this Keeper that delivers a receipt. *)
  | Row_delivers_to_queue
      (** A wake of this Keeper whose delivery is [queue]. It never writes a
          receipt. *)
  | No_row
      (** No wake of this Keeper has this schedule id. *)

val find_schedule :
  base_path:string ->
  keeper_name:string ->
  string ->
  (schedule_row, string) result
(** The row with this schedule id. [Error] when the schedule store cannot be
    read or the row's payload does not decode. *)

val find_receipt_state :
  base_path:string ->
  keeper_name:string ->
  Schedule_supported_kinds.receipt_key ->
  (receipt_state option, string) result
(** The state of the wake of this Keeper that holds this key; [None] when no
    row does: it was pruned, or an edit gave the schedule a new key. [Error]
    when the schedule store cannot be read, or when no row holds the key and a
    row of this Keeper cannot be decoded, because that row may be the one. *)
