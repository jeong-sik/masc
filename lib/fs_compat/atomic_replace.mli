(** Atomic replacement with process-restart sync.

    The strict contract is
    [tmp → Unix.fsync(tmp) → rename → Unix.fsync(parent dir)]. Successful
    return means both Unix sync calls returned successfully and supports
    process-restart recovery. It does not claim hardware/power-loss
    persistence and does not use Darwin [F_FULLFSYNC].

    The [save_file] primitive is injected so this module stays free of
    [Fs_compat]'s Eio bridge; it must be a blocking writer, because the
    replacement runs as one blocking job (a system thread inside Eio) from
    temp-file creation to the parent directory fsync. Orphan inventory and
    preservation are owned separately by [Atomic_orphan_cleanup]. *)

(** [save_file_atomic ~save_file path content] writes [content] to
    a temp file in [path]'s directory, fsyncs the tmp, renames it
    over [path], and best-effort fsyncs the parent directory.

    Returns [Ok ()] on success or [Error msg] when temp-file creation,
    writing, fsync, or rename fails (an existing tmp is cleaned up). Re-raises
    [Eio.Cancel.Cancelled] after cleaning up the tmp — cancellation
    must not be swallowed (RFC-0143). *)
val save_file_atomic
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

(** [save_file_atomic_rename_only ~save_file path content] writes [content]
    to a temp file in [path]'s directory and renames it over [path], with no
    fsync of the temp file or the parent directory. Readers see the old file
    or the new one, never a mix; after a power loss the renamed file can be
    empty or partial. Use it only for a file the caller rebuilds from its own
    source on the next pass. Errors and cancellation behave as in
    {!save_file_atomic}. *)
val save_file_atomic_rename_only
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

type atomic_replace_failure_stage =
  | Before_rename
  | After_rename

type atomic_replace_failure =
  { path : string
  ; stage : atomic_replace_failure_stage
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

val atomic_replace_failure_to_string : atomic_replace_failure -> string

val save_file_atomic_strict_staged
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, atomic_replace_failure) Result.t
(** Strict atomic replacement that preserves whether failure occurred before
    or after the target rename became visible. Payload [Unix.fsync] is
    mandatory before rename and parent-directory [Unix.fsync] is mandatory
    afterward. Cancellation is re-raised after staging cleanup with its
    original exception and backtrace; it is not returned as [Error]. If the
    rename already succeeded, the published target remains in place. *)

val write_file_atomic_strict_staged_blocking
  : string
  -> write:(out_channel -> unit)
  -> (unit, atomic_replace_failure) Result.t
(** Strict streaming replacement on the calling worker, without a thread hop.
    Only use in an existing blocking job. The callback and syncs obey the
    same staged publication contract as {!write_file_atomic_strict_staged}. *)

val write_file_atomic_strict_staged
  :  string
  -> write:(out_channel -> unit)
  -> (unit, atomic_replace_failure) Result.t
(** Stream bytes into the replacement using the same strict staged protocol.
    [write] runs synchronously in the blocking replacement job and must not
    perform Eio effects, close the channel, or retain it after returning.
    The writer closes the channel before syncing and publishing the file.
    Ordinary callback failures are returned as [Before_rename] with the
    original exception and backtrace. Cancellation is re-raised after staging
    cleanup with its original exception and backtrace. *)

(** Strict sibling of {!save_file_atomic}. Payload or parent-directory
    descriptor/fsync failure is returned as [Error] instead of being treated
    as best effort. *)
val save_file_atomic_strict
  :  save_file:(string -> string -> unit)
  -> string
  -> string
  -> (unit, string) Result.t

module For_testing : sig
  val save_file_atomic_strict_staged
    :  ?sync_file:(string -> unit)
    -> sync_parent:(string -> unit)
    -> save_file:(string -> string -> unit)
    -> string
    -> string
    -> (unit, atomic_replace_failure) Result.t

  val write_file_atomic_strict_staged
    :  ?sync_file:(string -> unit)
    -> sync_parent:(string -> unit)
    -> string
    -> write:(out_channel -> unit)
    -> (unit, atomic_replace_failure) Result.t
end

(** [open_atomic_temp_file ~temp_dir ()] creates and opens a fresh
    temp file in [temp_dir] using the canonical [.atomic_*.tmp]
    filename shape. The caller owns the returned channel and file. *)
val open_atomic_temp_file : temp_dir:string -> unit -> string * out_channel
