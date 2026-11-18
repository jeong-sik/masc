(** Per-path bounded LRU descriptor cache for the JSONL append
    write-path. RFC-0162 §3.4.

    Each path keeps one descriptor opened
    [O_APPEND | O_CREAT | O_RDWR | O_CLOEXEC], reused across calls.
    It is readable because a line append reads the file's last byte
    through it.
    The cache holds a descriptor and not an [out_channel]: a channel
    keeps the bytes of a failed write in its buffer and writes them
    with the next append or when it is closed. The
    cache is bounded by [max_entries=32] with last-used eviction so
    fd count stays bounded regardless of how many paths the process
    appends to. A [Stdlib.at_exit] hook closes every cached writer
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
    Evicts the least-recently-used inactive writer when
    the bound is exceeded. Active writers are leased until [f] returns,
    so LRU eviction cannot close a descriptor while a caller is
    still writing to it. Opening the file fails with [Sys_error]. *)
val with_writer : string -> (Unix.file_descr -> 'a) -> 'a

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
