(** Per-path bounded LRU descriptor cache for the JSONL append
    write-path. RFC-0162 §3.4.

    Each path keeps one descriptor opened by
    {!Fd_append_whole.open_target}, reused across calls: a regular
    file [O_APPEND | O_CREAT | O_RDWR | O_CLOEXEC], readable because
    a line append reads the file's last byte through it, and
    anything else (a FIFO, a device) write-only.
    The cache holds a descriptor and not an [out_channel]: a channel
    keeps the bytes of a failed write in its buffer and writes them
    with the next append or when it is closed. The
    cache holds at most [max_entries=32] writers, closing the least
    recently used one that is not lent, so the fd count stays bounded
    regardless of how many paths the process appends to. Writers that
    are lent are never closed, so more than 32 are held while more than
    32 paths are appended to at once, and the cache comes back to 32 as
    they are returned. A [Stdlib.at_exit] hook closes every cached writer
    on process exit; production code relies on process-lifetime
    persistence between exits.

    Boundary: this module owns *only* the bounded LRU descriptor
    cache. It is intentionally unaware of mkdir, write
    serialization, or test-isolation guards — those stay with the
    [Fs_compat] append site, which composes them around
    [with_writer]. *)

(** [with_writer path f] runs [f] with the cached writer for [path],
    opening one on the first request and bumping its LRU stamp on
    every request. Before reuse, the open descriptor must still identify the
    file at [path]; a removed/replaced path opens a fresh writer. This detects
    changes between leases, not a concurrent external rename during [f].
    Active writers are leased until [f] returns,
    so LRU eviction cannot close a descriptor while a caller is
    still writing to it. A path that has no cached writer is opened
    outside the cache's own lock, so an open that waits (a FIFO without
    a reader) holds up no other path. When the cache is full, the least
    recently used inactive writer is closed before that open, so a
    process at its descriptor limit can still open the new path; if the
    open then fails, the closed writer is opened again by its next
    append. An open in flight counts as one of the 32, so an open that
    waits takes one place from the cache for as long as it waits. The
    check that a cached descriptor still identifies the file (one [stat]
    call against the descriptor's immutable device and inode captured at
    open) runs inside the lock.
    @raise Sys_error when the path cannot be examined or opened. The
    message starts with [path] as it was given. *)
val with_writer : string -> (Fd_append_whole.target -> 'a) -> 'a

(** [invalidate path] closes and drops the cached writer for
    [path] when present (a no-op otherwise). Call it after the inode at
    [path] is replaced (e.g. an atomic-rename save) so a later
    [with_writer] reopens the new file rather than appending to the
    orphaned pre-replacement inode. This module only guards cache state;
    callers that compose [invalidate] with append operations must hold
    the same per-path append mutex used around [with_writer] and
    the write. *)
val invalidate : string -> unit

(** Close every cached writer. Active writers are removed from
    the cache and closed when their current lease returns; a subsequent
    [with_writer] opens fresh. Registered at [Stdlib.at_exit]. *)
val close_all : unit -> unit

(** Drop and close every cached writer. Test-only — production
    relies on process-lifetime persistence and the [at_exit] drain. *)
val reset_for_testing : unit -> unit
