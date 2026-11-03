(** Says that what [GET /api/v1/keepers/turns] answers for one Keeper may have
    changed (RFC-0481 §3.4).

    The event is [{"type":"keeper_turn_changed","name":<keeper>,"ts_unix":...}].
    It carries the Keeper name only; a reader that shows turns reads them
    again. It goes to the observers of [base_path]'s runtime only.

    It is sent after the write it announces: the Owner's turn slot and
    shutdown operation id, a chat control token rotation, the autonomous turn
    ref, and the Owner pool opening an Owner or failing to. Callers send it
    from inside their own locks and finally blocks, so it must not yield and
    must not raise. An exception from [Sse.broadcast_to] or from resolving the
    runtime, a [Cancelled] included, is counted on
    [keeper_sse_broadcast_failures] and logged at WARN. *)

val changed_event : string

val changed : base_path:string -> keeper_name:string -> unit
