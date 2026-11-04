(** Says that the runtime.toml text changed (RFC-0480 §3.4).

    Every server writer of the file goes through
    {!Runtime.commit_config_text_locked}, which moves
    {!Runtime.config_text_revision} once the new text is visible on disk.
    [install ~sw ~base_path] forks a fiber on [sw] that waits for each move
    without polling and sends {!Runtime_config_changed_event} to [base_path]'s
    observers. Commits that land together send one signal. An edit
    made to the file outside the server has no writer here and is not
    announced.

    A failed broadcast is counted on [keeper_sse_broadcast_failures] and logged
    at WARN; the fiber keeps waiting. *)

val install : sw:Eio.Switch.t -> base_path:string -> unit
