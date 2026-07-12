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

(** Whether an atomic write failure happened before or after the rename commit
    point. After-rename failure means the new file is visible in the current
    process but crash durability could not be proven. *)
type failure_stage =
  | Not_renamed
  | Renamed_durability_uncertain

type failure =
  { stage : failure_stage
  ; message : string
  }

val failure_to_string : failure -> string

(** [save_file_atomic_detailed ~save_file path content] writes [content] to
    a temp file in [path]'s directory, fsyncs the tmp, renames it over [path],
    and fsyncs the parent directory. No fsync failure is swallowed.

    [Not_renamed] proves the old target remains authoritative.
    [Renamed_durability_uncertain] means the new target is already visible and
    callers must not roll in-memory state back to the old revision. *)
val save_file_atomic_detailed
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, failure) Result.t

(** Compatibility wrapper around {!save_file_atomic_detailed}.

    Returns [Error msg] for every durability failure, preserving the existing
    explicit-failure API while erasing only the stage. Stateful callers that
    might roll memory back must use {!save_file_atomic_detailed} to distinguish
    the rename commit point. Re-raises
    [Eio.Cancel.Cancelled] after cleaning up the tmp — cancellation
    must not be swallowed (RFC-0143). *)
val save_file_atomic
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

(** [true] iff [name] matches the [.atomic_*.tmp] shape produced
    by {!save_file_atomic}. Exposed so a periodic sweep can match
    the same filename pattern without re-deriving the prefix and
    suffix — #10205 finding 2. *)
val is_atomic_orphan_name : string -> bool

(** #10130: boot-time sweep for [.atomic_*.tmp] orphans.

    Scans [base_path] and its immediate subdirectories (skipping
    [recovered_subdir] and anything that isn't a directory).
    - Zero-byte orphans are deleted (they lost the rename race
      but never held data).
    - Non-zero orphans are MOVED to
      [<base_path>/<recovered_subdir>/<original-name>.<ts-ms>]
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
