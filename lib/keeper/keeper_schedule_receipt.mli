(** The receipt of a Keeper wake whose delivery is [receipt]
    ({!Schedule_supported_kinds.Keeper_wake_to_receipt}).

    A due wake of that delivery reaches its Keeper as a tool-result receipt in
    the outbox, the way a background run's result does. [call_id] is the
    schedule id, so a turn that ended on [keeper_receipt_wait] for
    that id continues with it. The schedule id survives an edit and the
    settling of a run watch. The schedule instance id does not: both rewrite the
    row under a new instance id, so it cannot key a receipt. *)

type ending =
  | Delivered of { message : string }
      (** The wake is due. [message] is the text the schedule holds: for a
          watched run, the run's outcome and URL followed by the Keeper's own
          message. *)
  | Unfinished of { cause : string }
      (** The schedule ended without writing its receipt. *)

val receipt : schedule_id:string -> ending -> Keeper_client_tool_outbox.receipt

val deliver :
  base_path:string ->
  keeper_name:string ->
  schedule_id:string ->
  ending ->
  (unit, string) result
(** Retains the receipt and wakes the Keeper through the outbox. A receipt that
    is already in the outbox is not written again. The receipt is committed
    even when the wake cannot be: the maintenance pulse finds a retained
    receipt on its next pass. *)

val retain_unfinished :
  base_path:string ->
  keeper_name:string ->
  schedule_id:string ->
  (unit, string) result
(** Writes one [Unfinished] receipt for a schedule that ended without one, so a
    conversation that waits for it receives an answer. Does not wake the
    Keeper: the caller resolves the wait, and a wake before that would find the
    receipt owned and read nothing. Nothing is written when the outbox already
    holds a receipt of that call id. *)
