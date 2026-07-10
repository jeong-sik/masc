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

type not_committed_stage =
  | Open_parent_directory
  | Create_temporary
  | Configure_temporary
  | Write_temporary
  | Sync_temporary
  | Close_temporary

type uncertain_commit_stage =
  | Rename_target
  | Sync_parent_directory
  | Close_parent_directory

type temporary_cleanup =
  | No_temporary
  | Temporary_removed of { temporary_path : string }
  | Temporary_absent of { temporary_path : string }
  | Temporary_cleanup_failed of
      { temporary_path : string
      ; message : string
      }

type strict_write_error =
  | Not_committed of
      { path : string
      ; stage : not_committed_stage
      ; message : string
      ; cleanup : temporary_cleanup
      }
  | Commit_durability_unknown of
      { path : string
      ; stage : uncertain_commit_stage
      ; message : string
      ; cleanup : temporary_cleanup
      }

val not_committed_stage_label : not_committed_stage -> string
val uncertain_commit_stage_label : uncertain_commit_stage -> string
val temporary_cleanup_label : temporary_cleanup -> string
val strict_write_error_to_string : strict_write_error -> string

val save_file_atomic_strict
  : string -> string -> (unit, strict_write_error) result
(** Same atomic replacement contract as {!save_file_atomic}, but parent
    directory fd is opened before the temp file and fsynced after rename.
    Failures proven to precede the rename call return {!Not_committed}.  Every
    rename failure and every post-rename failure returns
    {!Commit_durability_unknown}: errno classification is not evidence that a
    namespace mutation did not occur on every supported filesystem, so callers
    must not reopen a deletion gate after the rename boundary.  The
    implementation owns and closes the temp channel, so buffer flush and fsync
    cannot drift from the write contract. *)

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
