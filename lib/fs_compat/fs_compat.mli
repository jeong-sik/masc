(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

module Atomic_orphan_size_class = Atomic_orphan_size_class

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

type exact_path_kind =
  | Exact_missing
  | Exact_kind of Unix.file_kind
  | Exact_unknown

(** Eio-native exact path classification. Unlike {!path_kind}, this preserves
    regular files, symbolic links, FIFOs, sockets, and devices as distinct
    [Unix.file_kind] values. [follow=false] is suitable for owned-file read
    boundaries that must reject links and special files before I/O. *)
val exact_path_kind : ?follow:bool -> string -> exact_path_kind

type path_kind =
  | Missing
  | Directory
  | Other

(** Coarse projection of {!exact_path_kind}. [follow=false] classifies a
    symbolic link as [Other] instead of classifying its target. Non-missing
    I/O failures remain explicit. *)
val path_kind : ?follow:bool -> string -> path_kind

type owned_directory_chain_rejection = Owned_directory_chain.rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type owned_directory_chain_observation = Owned_directory_chain.observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

val inspect_owned_directory_chain
  :  ownership_root:string
  -> string
  -> (owned_directory_chain_observation, owned_directory_chain_rejection) result
(** Shared no-follow ownership-boundary inspection. *)

val owned_directory_chain_rejection_to_string
  :  owned_directory_chain_rejection
  -> string

val owned_directory_paths
  :  ownership_root:string
  -> string
  -> (string list, owned_directory_chain_rejection) result
(** Lexical ordered descendant paths for ownership-aware directory creation. *)

(** Eio-native, deterministically sorted directory inventory. *)
val read_dir : string -> string list

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

(** [open_atomic_temp_file ~temp_dir ()] creates and opens a fresh
    temp file in [temp_dir] using the canonical [.atomic_*.tmp]
    filename shape. The caller owns the returned channel and file. *)
val open_atomic_temp_file : temp_dir:string -> unit -> string * out_channel

(** [true] iff [name] matches the canonical [.atomic_*.tmp] pattern produced by
    this module. Exposed for tests and recovery sweeps. *)
val is_atomic_orphan_name : string -> bool

type atomic_orphan_cleanup_scope =
  | Directory_only
  | Directory_and_immediate_subdirectories

type atomic_orphan_cleanup_operation =
  | Inspect_cleanup_root
  | Read_cleanup_directory
  | Inspect_orphan
  | Create_recovery_directory
  | Sync_recovery_parent
  | Link_preserved_orphan
  | Verify_preserved_orphan
  | Sync_preserved_orphan
  | Sync_recovery_directory
  | Delete_empty_orphan
  | Delete_preserved_source
  | Sync_source_directory
  | Close_cleanup_descriptor

type atomic_orphan_cleanup_cause =
  | Unix_failure of Unix.error * string * string
  | Sys_failure of string
  | Unexpected_file_kind of Unix.file_kind
  | Outside_ownership_root of { ownership_root : string }
  | Identity_changed
  | Other_failure of exn

type atomic_orphan_cleanup_failure =
  { operation : atomic_orphan_cleanup_operation
  ; path : string
  ; cause : atomic_orphan_cleanup_cause
  }

type atomic_orphan_cleanup_report =
  { inspected : int
  ; deleted : int
  ; preserved : int
  ; failures : atomic_orphan_cleanup_failure list
  }

val atomic_orphan_cleanup_failure_to_string
  :  atomic_orphan_cleanup_failure
  -> string

(** No-follow orphan cleanup. [Directory_only] is bounded by the named
    staging inventory. The broader scope also scans real immediate child
    directories. Every failed mutation or unexpected orphan-shaped entry is
    returned in the typed report. The caller must own stable directory
    identities and quiesce the matching temp namespace; see
    {!Atomic_write.cleanup_atomic_orphans} for the OCaml 5.4 dirfd
    limitation. *)
val cleanup_atomic_orphans
  :  ownership_root:string
  -> base_path:string
  -> scope:atomic_orphan_cleanup_scope
  -> unit
  -> atomic_orphan_cleanup_report

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

type durable_append_operation =
  | Write
  | Append_fsync
  | Rollback_truncate
  | Rollback_fsync

type durable_append_failure =
  | Unix_error of
      { operation : durable_append_operation
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | No_write_progress

type durable_append_error =
  { append_failure : durable_append_failure
  ; rollback_failures : durable_append_failure list
  }

(** Render a structured durable-append failure without discarding the original
    [Unix.error] or rollback failures. *)
val durable_append_error_to_string : durable_append_error -> string

(** [update_private_file_durable_locked_result path decide] serializes in-process
    callers with the shared per-path append mutex, takes a cross-process file
    lock, reads the exact existing bytes, and calls [decide]. [Some suffix]
    appends the complete suffix and fsyncs it before returning [Ok]; [None]
    performs no write. If writing or the append fsync fails, the file is
    truncated to its original length and that rollback is fsynced. [Error]
    preserves the append failure and every rollback failure. Setup, read, and
    [decide] exceptions still propagate. The file is created with mode [0600],
    and every transaction fsyncs its parent directory before touching payload
    bytes so a failed creation can be retried without silently skipping that
    durability boundary. Filesystems that reject directory fsync fail
    explicitly. The shared path mutex serializes this operation with cached
    JSONL writers without closing their already-flushed descriptors. When the
    Eio filesystem is active, the transaction and [decide] run in a system
    thread so a contended file cannot stop unrelated fibers; [decide] therefore
    must not perform Eio effects. *)
val update_private_file_durable_locked_result :
  string -> (string -> string option * 'a) -> ('a, durable_append_error) result

type private_jsonl_append_error =
  | Incomplete_jsonl_tail
  | Invalid_jsonl_suffix
  | Durable_jsonl_append_failed of durable_append_error

(** Append one or more complete JSONL rows without reading the existing file.
    The operation holds the same in-process and cross-process path locks as
    {!update_private_file_durable_locked_result}, verifies only that an existing
    file ends at a newline boundary, then appends and fsyncs with rollback on
    failure. Every transaction also fsyncs the parent directory. Runtime cost
    is proportional to [suffix], not to historical file size. When the Eio
    filesystem is active, the entire blocking lock/write/fsync transaction runs
    in a system thread so one contended file cannot stop unrelated fibers. *)
val append_private_jsonl_durable_locked_result :
  string -> string -> (unit, private_jsonl_append_error) result

val private_jsonl_append_error_to_string : private_jsonl_append_error -> string

type durable_append_io_for_testing =
  { write : Unix.file_descr -> bytes -> int -> int -> int
  ; ftruncate : Unix.file_descr -> int -> unit
  ; fsync : Unix.file_descr -> unit
  }

(** Direct fd-level seam for deterministic partial-write and rollback tests.
    Production code uses the same implementation with [Unix] operations. *)
val append_fd_durable_for_testing :
  io:durable_append_io_for_testing ->
  fd:Unix.file_descr ->
  original_length:int ->
  string ->
  (unit, durable_append_error) result

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
