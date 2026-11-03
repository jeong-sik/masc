(** Says that one Keeper's roster row may have changed (RFC-0481 §3.2).

    The event is [{"type":"keeper_row_changed","name":<keeper>,"ts_unix":...}].
    It carries the Keeper name only. A reader that shows the row reads
    [GET /api/v1/gate/keepers?detailed=true&name=<keeper>] again; that read
    never uses the list cache, so no cache is dropped before the event. It
    goes to the observers of [base_path]'s runtime only, as
    [keeper_waiting_inventory_changed] does.

    {!Keeper_registry_setup} sends it when a committed registry swap changes
    the Keeper's phase or its failure (reason or time).

    {!Keeper_owner} sends it after each metadata write it commits, once the
    Owner's projection is updated. It also sends it after a write that raised,
    and after the write failure that fences the Owner's metadata store, because
    a failed durable write can still have changed the file. A transition that
    persists nothing sends nothing.

    Both callers send it after their write has committed (the Owner on its own
    fiber, the registry inside its lifecycle key lock), so a failure here must
    not fail the write and the send must not yield. An exception from
    [Sse.broadcast_to] or from resolving [base_path]'s runtime, a [Cancelled]
    it raises itself included, is counted on [keeper_sse_broadcast_failures]
    and logged at WARN; a cancellation of the calling fiber is still raised by
    [Eio.Fiber.check]. *)

val row_changed_event : string

val changed : base_path:string -> keeper_name:string -> unit

val roster_changed_event : string

val roster_changed : base_path:string -> unit
(** [{"type":"keeper_roster_changed","ts_unix":...}]: a Keeper entered or
    left [base_path]'s registry. A reader rereads the whole roster with
    [fresh=true]. {!Keeper_registry_setup} sends it from the one place a
    registry swap commits; a changed entry whose phase or failure moved sends
    {!changed} for that Keeper instead. It goes to the same observers as
    {!changed} and fails the same way. *)
