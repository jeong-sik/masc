(** The receipt of a Keeper wake whose delivery is [receipt]
    ({!Schedule_supported_kinds.Keeper_wake_to_receipt}).

    A due wake of that delivery reaches its Keeper as a tool-result receipt in
    the outbox, the way a background run's result does. [call_id] is the
    schedule instance id, so a turn that ended on [keeper_receipt_wait] for
    that id continues with it. *)

type ending =
  | Delivered of { message : string }
      (** The wake is due. [message] is the text the schedule holds: for a
          watched run, the run's outcome and URL followed by the Keeper's own
          message. *)
  | Unfinished of { cause : string }
      (** The schedule ended without writing its receipt. *)

val receipt : schedule_instance_id:string -> ending -> Keeper_client_tool_outbox.receipt

val deliver :
  base_path:string ->
  keeper_name:string ->
  schedule_instance_id:string ->
  ending ->
  (unit, string) result
(** Retains the receipt and wakes the Keeper through the outbox. A receipt that
    is already in the outbox is not written again. The receipt is committed
    even when the wake cannot be: the maintenance pulse finds a retained
    receipt on its next pass. *)
