(** Says that a file one Keeper's memory health row reads was written
    (RFC-0487).

    The stores that keep those files call {!written} once a write succeeded:
    the memory journal for the lines written outside a publication (an
    unchanged commit, a Librarian failure, a snapshot quarantine), the unread
    ledger when the archive changed it, the continuity snapshot, the Librarian
    progress, the turn boundaries and the turn records. The memory and source
    snapshots, and the journal lines a publication writes, are announced by
    {!Keeper_memory_commit_notifications}, which a reader of this signal also
    subscribes to.

    It is a wake signal: it names the Keeper and the keepers directory the
    file lives under, not what was written. A reader reads the row again. *)

type event =
  { keepers_dir : string
      (** The keepers directory, resolved through symlinks as
          {!Keeper_memory_commit_notifications.event} names it, so one
          comparison matches both signals. *)
  ; keeper_id : string
  }

val subscribe : (event -> unit) -> (unit -> unit)
(** Register a callback and return an idempotent unsubscribe function.
    Callbacks run synchronously on the writer's domain, often while the store
    still holds its lock, so they must not read files, block or yield. *)

val written : keepers_dir:string -> keeper_id:string -> unit
(** Run every callback for [keeper_id]'s file under [keepers_dir]. With no
    subscriber it does nothing, so a process that does not serve the health
    row pays nothing. A callback that raises is logged at WARN and does not
    stop the others; a cancellation is raised again once all of them ran. A
    directory that no longer resolves, removed since the write, is logged at
    WARN and calls nothing. Never raises otherwise. *)
