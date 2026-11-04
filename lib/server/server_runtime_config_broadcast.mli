(** Says that this server process committed a runtime.toml text
    (RFC-0480 §3.4).

    The server's writers of the file go through
    {!Runtime.commit_config_text_locked}, which moves
    {!Runtime.config_text_revision} once the new text is visible on disk. The
    startup journal rollback and config-root seeding write it before this
    fiber is installed and before the listener starts, so no reader misses
    them. The TUI saves through this server's routes and has no writer of its
    own. [masc config set], [masc web-search-setup], [masc voice-local-setup]
    and [masc runtime-default-set] save through them while this server runs,
    and write the file in their own process only when no server of this
    workspace answers. [masc runtime-setup-batch] and
    [masc browser-lane-setup] write it in their own process either way
    (RFC-0482 L3d); this process does not see those writes.
    [install ~sw ~base_path] forks a fiber on [sw] that waits for each move
    without polling and sends {!Runtime_config_changed_event} to [base_path]'s
    observers. Commits that land together send one signal. An edit
    made to the file outside the server has no writer here and is not
    announced.

    A failed broadcast is counted on [keeper_sse_broadcast_failures] and logged
    at WARN; the fiber keeps waiting. *)

val install : sw:Eio.Switch.t -> base_path:string -> unit
