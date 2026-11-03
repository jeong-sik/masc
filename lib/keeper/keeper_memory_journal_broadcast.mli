(** Says that a Keeper's memory journal has a new row.

    {!Keeper_memory_os_current.append_journal_line_strict}, the one function
    that adds rows to the journal, calls it after the durable append returns.
    The event carries the Keeper name only; a reader that shows the journal
    reads [/api/v1/keepers/:name/memory-journal] again.

    The journal is addressed by its keepers directory, which a config override
    can place outside any workspace, so the event goes to every observer like
    [keeper_chat_appended]. Exceptions from [Sse.broadcast] are counted on the
    [keeper_sse_broadcast_failures] counter (site
    [memory_journal_appended]) and logged at WARN. {!Eio.Cancel.Cancelled}
    propagates. *)
val appended : keeper_name:string -> unit
