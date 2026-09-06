(** The language-server pool a turn is using, bound the way its switch is.

    RFC a-language-server-the-keeper-can-ask §6 asked whether a Keeper's
    language server should belong to the turn or be shared across turns. This
    is the answer, and it is the measured one.

    Starting a server is cheap: [initialize] against a real [ocamllsp] answered
    in 11-60 ms. Keeping one is not: an idle server on this host held 12-17 MB
    and one that had answered questions held 155 MB. A server-scoped pool keys
    on [(language, workspace_root)] and every Keeper has its own sandbox root,
    so ten Keepers would hold ten servers for as long as the process lives. The
    turn pays tens of milliseconds; the alternative pays gigabytes for the
    life of the server.

    What a turn-scoped pool does not amortize is the language server's own
    indexing, which shows up on the first question rather than at [initialize]
    — 2,200 ms once, measured. If that turns out to dominate, this is the file
    that changes, and the evidence for changing it is a timing, not a
    preference. *)

(** Bind a pool for the current fiber and the fibers forked from it, and shut
    every language server it started down before returning. Call from inside
    the turn body, so what reads it during the turn is what the turn created.

    A turn that cannot reach an Eio environment runs without a pool rather than
    failing over a capability it may never use — {!get_opt} answers [None] and
    the tool says so. *)
val with_turn_pool : servers:Lsp_process_manager.servers -> (unit -> 'a) -> 'a

val get_opt : unit -> Lsp_workspace_pool.t option
(** [None] outside a turn, and inside one that has no pool. *)
