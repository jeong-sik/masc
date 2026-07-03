(** Per-path bounded LRU [out_channel] cache for the JSONL append
    write-path. RFC-0162 §3.4.

    Each path keeps one [Stdlib.open_out_gen] writer in
    [O_APPEND | O_CREAT | O_WRONLY] mode, reused across calls. The
    cache is bounded by [max_entries=32] with last-used eviction so
    fd count stays bounded regardless of how many paths the process
    appends to. A [Stdlib.at_exit] hook closes every cached writer
    on process exit; production code relies on process-lifetime
    persistence between exits.

    Boundary: this module owns *only* the bounded LRU [out_channel]
    cache. It is intentionally unaware of mkdir, write
    serialization, or test-isolation guards — those stay with the
    [Fs_compat] append site, which composes them around
    [get_writer]. *)

(** [get_writer path] returns the cached writer for [path],
    opening one on the first request and bumping its LRU stamp on
    every request. Evicts the least-recently-used writer when the
    bound is exceeded. Internal mutex protects cache state only;
    {b does not} stay held across the caller's subsequent
    [output_string]/[flush] on the returned channel. *)
val get_writer : string -> out_channel

(** [invalidate path] flushes, closes, and drops the cached writer for
    [path] when present (a no-op otherwise). Call it after the inode at
    [path] is replaced (e.g. an atomic-rename save) so a later
    [get_writer] reopens the new file rather than appending to the
    orphaned pre-replacement inode. The caller must ensure no concurrent
    append is in flight on [path] (the cached channel is closed), which
    the JSONL store guarantees by holding its per-partition write lock. *)
val invalidate : string -> unit

(** Flush and close every cached writer. Safe to call concurrently
    with active appends; a subsequent [get_writer] re-opens fresh.
    Registered at [Stdlib.at_exit]. *)
val close_all : unit -> unit

(** Drop and close every cached writer. Test-only — production
    relies on process-lifetime persistence and the [at_exit] drain. *)
val reset_for_testing : unit -> unit
