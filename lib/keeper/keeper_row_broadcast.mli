(** Says that one Keeper's roster row may have changed (RFC-0481 §3.2).

    The event is [{"type":"keeper_row_changed","name":<keeper>,"ts_unix":...}].
    It carries the Keeper name only. A reader that shows the row reads
    [GET /api/v1/gate/keepers?detailed=true&name=<keeper>] again; that read
    never uses the list cache, so no cache is dropped before the event. An
    answer with no row means the Keeper has none, and a name the reader has
    not seen is a new row. It goes to the observers of [base_path]'s runtime
    only, as [keeper_waiting_inventory_changed] does.

    {!Keeper_registry_setup} sends it when a committed registry swap adds or
    removes the Keeper's entry, or changes its phase or its failure (reason or
    time). {!Keeper_execution_receipt.append} sends it after each receipt
    append.

    {!Keeper_owner} sends it after each metadata write it commits, once the
    Owner's projection is updated. It also sends it after a write that raised,
    and after the write failure that fences the Owner's metadata store, because
    a failed durable write can still have changed the file. A transition that
    persists nothing sends nothing.

    Every caller sends it after its write has committed (the Owner on its own
    fiber, the registry inside its lifecycle key lock), so the send must not
    yield and must not fail the write. An exception from [Sse.broadcast_to] or
    from resolving [base_path]'s runtime, a [Cancelled] included, is counted
    on [keeper_sse_broadcast_failures] and logged at WARN. *)

val row_changed_event : string

val changed : base_path:string -> keeper_name:string -> unit

val roster_changed_event : string

val roster_changed : base_path:string -> unit
(** [{"type":"keeper_roster_changed","ts_unix":...}]: a value every row of
    [base_path]'s roster reads changed, so a reader rereads the whole roster
    with [fresh=true]. {!Server_runtime_assignment_broadcast} sends it on
    each runtime catalogue publication. It goes to the same observers as
    {!changed} and fails the same way. *)
