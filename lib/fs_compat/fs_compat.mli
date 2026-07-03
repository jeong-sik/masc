(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

(** #9921: raised by mutating [Fs_compat] entry points
    ([append_file], [save_file], [mkdir_p]) when the target path falls
    under [HOME] and the process is a test executable. Defense in depth
    behind [Env_config_core.base_path_prod_guard]. Bypass with
    [MASC_TEST_ALLOW_HOME_BASE_PATH=1]. *)
exception Test_isolation_breach of string

(** Set global Eio filesystem. Call at server startup. *)
val set_fs : Eio.Fs.dir_ty Eio.Path.t -> unit

(** Clear global fs (testing/shutdown). *)
val clear_fs : unit -> unit

(** Get the global Eio filesystem if available. *)
val get_fs_opt : unit -> Eio.Fs.dir_ty Eio.Path.t option

(** Check if Eio fs is available. *)
val has_fs : unit -> bool

(** Load entire file as string. *)
val load_file : string -> string

(** Load entire file as string, or [None] when the file is missing.
    Option-returning sibling of {!load_file} (which raises on a missing
    path). Other I/O failures of an existing file propagate as
    [Sys_error]. *)
val load_file_opt : string -> string option

(** Save string to file (overwrite). *)
val save_file : string -> string -> unit

(** Write content to path via temp file + rename.
    Returns [Error msg] on I/O failure instead of raising. *)
val save_file_atomic : string -> string -> (unit, string) Result.t

(** [true] iff [name] matches the [.atomic_*.tmp] pattern produced
    by [Filename.temp_file ~temp_dir:dir ".atomic_" ".tmp"] inside
    {!save_file_atomic}.  Exposed for tests and for a potential
    periodic sweep. *)
val is_atomic_orphan_name : string -> bool

(** #10130: boot-time sweep for [.atomic_*.tmp] orphans left
    behind when [save_file_atomic]'s with-handler never ran (the
    owning process was SIGKILL'd, or [Filename.temp_file] itself
    raised ENFILE/EMFILE before the cleanup was registered).

    Scans [base_path] and its immediate subdirectories (skipping
    [recovered_subdir] and anything that isn't a directory).
    - Zero-byte orphans are deleted.
    - Non-zero orphans are moved to
      [<base_path>/<recovered_subdir>/<original-name>.<ts-ms>]
      so operators can forensically inspect data-loss events
      instead of having them silently cleaned up.

    Returns [(deleted, preserved)]:
    - [deleted]: zero-byte orphans removed.
    - [preserved]: non-zero orphans moved to [recovered_subdir]. *)
val cleanup_atomic_orphans
  :  base_path:string
  -> ?recovered_subdir:string
  -> unit
  -> int * int

(** Append string to file. *)
val append_file : string -> string -> unit

(** Check if file exists. *)
val file_exists : string -> bool

(** Return file size or None *)
val file_size : string -> int option

(** Return file mtime or None *)
val file_mtime : string -> float option

(** Rename file. *)
val rename : string -> string -> unit

(** [rename_if_exists ~src ~dst] renames [src] to [dst], returning [true]
    on success and [false] if [src] did not exist. Other I/O errors
    propagate as [Sys_error] (Eio.Io is normalized internally, matching
    {!rename}). Both runtime paths recognize the missing-source case
    via typed catches ([Eio.Fs.Not_found] / verified [Sys.file_exists])
    rather than substring matching on the libc message. *)
val rename_if_exists : src:string -> dst:string -> bool

(** Remove directory. *)
val rmdir : string -> unit

(** Remove a file, symlink, or directory tree without invoking a shell.
    Missing paths are ignored.  Symlinks are unlinked, not followed. *)
val remove_tree : string -> unit

(** Get realpath. *)
val realpath : string -> string

(** Create directory recursively. *)
val mkdir_p : string -> unit

(** [mkdir_p_memoized path] is [mkdir_p] but skips the stat/mkdir
    syscalls on every call after the first for the same [path].
    Use on hot append paths (jsonl writers, ledger appends) where the
    same dir is touched many times per second. RFC-0162 §3.1.

    The cache caches only the *fact* of dir existence; no fd is held.
    External processes that delete the dir after first call will see
    silent skip — acceptable for [.masc/] (self-owned). *)
val mkdir_p_memoized : string -> unit

(** Reset the [mkdir_p_memoized] cache. Test-only — production code
    relies on process-lifetime persistence. *)
val reset_mkdir_memo_for_testing : unit -> unit

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
val load_jsonl : string -> Yojson.Safe.t list

(** Load JSONL file, returning parsed values and count of malformed lines.
    Logs each malformed line with the provided source label. Use when the caller needs
    to surface degraded state (e.g. dashboard malformed_lines field). *)
val load_jsonl_diagnostics : string -> Yojson.Safe.t list * int

(** Parse pre-read string lines as JSONL, returning parsed values and
    malformed count.  [source] is used in log messages.
    Use when lines come from tail-readers or non-file sources. *)
val parse_jsonl_lines : source:string -> string list -> Yojson.Safe.t list * int

(** Stream JSONL line-by-line via [Eio.Buf_read.lines] when the global
    fs is registered, falling back to a raw-line iterator over the
    Stdlib channel otherwise (both branches share the same [line_no]
    counting).  [line_no] is the 1-based index of {b non-blank}
    JSONL rows — blank lines are skipped, malformed lines emit a
    stderr warning and are skipped but {i still consume} the index
    so the counter tracks the printed JSONL row number rather than
    the count of successfully parsed values.  Use when the file may
    be too large to materialize as a list, e.g. audit/metrics JSONL
    on HTTP hot paths.

    Returns [init] when [path] is missing (consistent with
    {!load_jsonl}); raises [Sys_error] on read failures of an
    existing file. *)
val fold_jsonl_lines
  :  init:'acc
  -> f:('acc -> line_no:int -> Yojson.Safe.t -> 'acc)
  -> string
  -> 'acc

(** [fold_appended_lines ~path ~from ~init ~f] folds [f] over the raw
    non-blank, newline-terminated lines whose bytes start at offset
    [from], returning [(acc, boundary)] where [boundary] is the offset
    just past the last ['\n'] consumed.

    Contract for incremental readers over append-only JSONL stores:
    cache [(boundary, acc)] per path and pass the cached [boundary] as
    [from] on the next call — only the appended delta is re-read.
    Bytes after the last ['\n'] (a partially flushed line) are neither
    folded nor included in [boundary], so they are re-read once the
    writer completes the line. A [from] outside [0, file_size] (file
    truncated or rotated) restarts the scan from byte 0. Returns
    [(init, 0)] when [path] does not exist. Lines are raw strings;
    callers parse (and decide how to surface malformed rows). *)
(** [read_slice ~path ~from ~len] returns the byte slice
    [[from, from+len)] of the file, clamped to its current size.
    Missing file or empty clamped range returns [""]. Callers bound
    [len], so one call never scales with file size (RFC-0228 P1). *)
val read_slice : path:string -> from:int -> len:int -> string

val fold_appended_lines
  :  path:string
  -> from:int
  -> init:'acc
  -> f:('acc -> string -> 'acc)
  -> 'acc * int

(** Append JSON value as line to JSONL file.

    Backed by a process-local per-path fd cache (RFC-0162 §3.4).
    Each path keeps one cached [out_channel] reused across appends;
    cross-domain serialization is provided by the same per-path
    mutex registry as [append_file_unix], preserving RFC-0108 §3.2's
    Record-interleave-0 guarantee. The cache is bounded by
    [fd_cache_max=32] with LRU eviction; [close_all_cached_writers]
    is registered at [at_exit]. *)
val append_jsonl : string -> Yojson.Safe.t -> unit

(** [append_jsonl_batch path jsons] writes multiple JSON entries to [path]
    in a single lock+flush cycle. More efficient than calling [append_jsonl]
    repeatedly when batching pending entries. No-op if [jsons] is empty. *)
val append_jsonl_batch : string -> Yojson.Safe.t list -> unit

(** Flush and close every cached [out_channel] held by
    [append_jsonl]. Safe to call concurrently with active appends;
    a subsequent [append_jsonl] re-opens fresh. Intended for
    shutdown sequencing and rare administrative refresh.
    RFC-0162 §3.4. *)
val close_all_cached_writers : unit -> unit

(** [invalidate_cached_writer path] drops the cached [append_jsonl]
    writer for [path] (a no-op if none is cached). Call it after
    replacing the inode at [path] with [save_file_atomic]: the cached
    [O_APPEND] channel still points at the pre-rename inode, so without
    this a later [append_jsonl] would write to the orphaned file.
    Serialization with concurrent [append_jsonl] calls is handled by the
    same per-path append mutex used by the append path. *)
val invalidate_cached_writer : string -> unit

(** Drop and close every cached writer. Test-only — production
    relies on process-lifetime persistence and [at_exit] drain. *)
val reset_fd_cache_for_testing : unit -> unit

(** Lease the cached writer directly. Test-only — production callers
    should use {!append_jsonl} / {!append_jsonl_batch} so directory
    creation, HOME guards, and per-path write serialization stay composed
    at the public append boundary. *)
val with_cached_writer_for_testing : string -> (out_channel -> 'a) -> 'a
