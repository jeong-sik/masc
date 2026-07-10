(** Durable atomic write + crash-recovery orphan sweep.

    Owns the durability boundary that protects against partial
    writes, torn renames, and SIGKILL-during-write data loss. The
    contract is [tmp → fsync(tmp) → rename → fsync(parent dir)],
    so a crash between rename and the kernel's dirty-page flush
    cannot leave the target truncated or zero-length. Observed on
    [backlog.json] after an abrupt shutdown on 2026-04-18.

    Crash recovery is provided by [cleanup_atomic_orphans], a
    boot-time sweep for [.atomic_*.tmp] files left behind when the
    owning process was SIGKILL'd or [Filename.temp_file] itself
    raised ENFILE/EMFILE before the with-handler could register.

    The [save_file] and [mkdir_p_unix] primitives are injected so
    this module stays free of [Fs_compat]'s Eio bridge — same
    cycle-free placement pattern as [Mkdir_memo] and [Fd_cache]. *)

(** [save_file_atomic ~save_file path content] writes [content] to
    a temp file in [path]'s directory, fsyncs the tmp, renames it
    over [path], and best-effort fsyncs the parent directory.

    Returns [Ok ()] on success or [Error msg] when the write or
    rename fails (the tmp is cleaned up). Re-raises
    [Eio.Cancel.Cancelled] after cleaning up the tmp — cancellation
    must not be swallowed (RFC-0143). *)
val save_file_atomic
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

val fsync_directory : string -> (unit, string) result
(** Durably publish prior directory-entry changes. Unsupported-filesystem
    [EINVAL]/[EOPNOTSUPP] is treated as success by the underlying portability
    boundary; every other failure is returned explicitly. *)

(** [true] iff [name] matches the [.atomic_*.tmp] shape produced
    by {!save_file_atomic}. Exposed so a periodic sweep can match
    the same filename pattern without re-deriving the prefix and
    suffix — #10205 finding 2. *)
val is_atomic_orphan_name : string -> bool

type atomic_orphan_recovery =
  | Deleted_zero_length
  | Preserved_nonempty of string

val recover_atomic_orphan
  :  path:string
  -> recovered_root:string
  -> bucket:string
  -> (atomic_orphan_recovery, string) result
(** Reconcile one recognized atomic-write orphan. Zero-length files are
    deleted; non-empty files are fsynced and linked without overwrite into the
    existing real [recovered_root]/[bucket], then unlinked from the source. Both
    path components must be real directories and [bucket] must be one segment.
    A crash after linking is completed idempotently by inode identity. *)

(** #10130: boot-time sweep for [.atomic_*.tmp] orphans.

    Scans [base_path] and its immediate subdirectories (skipping
    [recovered_subdir] and anything that isn't a directory).
    - Zero-byte orphans are deleted (they lost the rename race
      but never held data).
    - Non-zero orphans are MOVED into a source-directory bucket under
      [<base_path>/<recovered_subdir>]
      so operators can forensically inspect data-loss events
      instead of having them silently cleaned up.

    Returns [(deleted, preserved)]:
    - [deleted]: zero-byte orphans removed.
    - [preserved]: non-zero orphans moved to [recovered_subdir]. *)
val cleanup_atomic_orphans
  :  mkdir_p_unix:(string -> unit)
  -> base_path:string
  -> ?recovered_subdir:string
  -> unit
  -> int * int
