(** Says that one Keeper's roster row may have changed (RFC-0481 §3.2).

    The event is [{"type":"keeper_row_changed","name":<keeper>,"ts_unix":...}].
    It carries the Keeper name only. A reader that shows the row reads
    [GET /api/v1/gate/keepers?detailed=true&name=<keeper>] again; that read
    never uses the list cache, so no cache is dropped before the event. It
    goes to the observers of [base_path]'s runtime only, as
    [keeper_waiting_inventory_changed] does.

    {!Keeper_owner} sends it after each metadata write it commits, once the
    Owner's projection is updated. It also sends it after a write that raised,
    and after the write failure that fences the Owner's metadata store, because
    a failed durable write can still have changed the file. A transition that
    persists nothing sends nothing.

    The Owner calls it on its own fiber after the command has committed, so a
    failure here must not fail the command. An exception from
    [Sse.broadcast_to] or from resolving [base_path]'s runtime, a [Cancelled]
    it raises itself included, is counted on
    [keeper_sse_broadcast_failures] and logged at WARN; a cancellation of the
    calling fiber is still raised by [Eio.Fiber.check]. *)

val row_changed_event : string

val changed : base_path:string -> keeper_name:string -> unit
