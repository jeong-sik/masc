(** The receipt of a Keeper wake whose delivery is [receipt]
    ({!Schedule_supported_kinds.Keeper_wake_to_receipt}).

    A due wake of that delivery reaches its Keeper as a tool-result receipt in
    the outbox, the way a background run's result does. [call_id] is the
    schedule's {!Schedule_supported_kinds.receipt_key}, so a turn that ended on
    [keeper_receipt_wait] for the schedule continues with it. Neither the
    schedule id nor the schedule instance id can key a receipt. A Keeper may
    pick the schedule id, so it can equal an Execute request id or name a
    schedule created again after the first was pruned. An edit and the settling
    of a run watch rewrite the row under a new instance id. The key is in the
    row's body, which both keep. *)

type ending =
  | Delivered of { schedule_id : string; message : string }
      (** The wake is due. [message] is the text the schedule holds: for a
          watched run, the run's outcome and URL followed by the Keeper's own
          message. [schedule_id] is what the Keeper knows the schedule by. *)
  | Unfinished of { cause : string }
      (** The schedule ended without writing its receipt. *)

val receipt :
  receipt_key:Schedule_supported_kinds.receipt_key ->
  ending ->
  Keeper_client_tool_outbox.receipt

val deliver :
  base_path:string ->
  keeper_name:string ->
  receipt_key:Schedule_supported_kinds.receipt_key ->
  ending ->
  (unit, string) result
(** Retains the receipt and wakes the Keeper through the outbox. A receipt that
    is already in the outbox is not written again. The receipt is committed
    even when the wake cannot be: the maintenance pulse finds a retained
    receipt on its next pass. *)

val retain_unfinished :
  base_path:string ->
  keeper_name:string ->
  receipt_key:Schedule_supported_kinds.receipt_key ->
  (unit, string) result
(** Writes one [Unfinished] receipt for a schedule that ended without one, so a
    conversation that waits for it receives an answer. Does not wake the
    Keeper: the caller resolves the wait, and a wake before that would find the
    receipt owned and read nothing. Nothing is written when the outbox already
    holds a receipt of that call id. *)
