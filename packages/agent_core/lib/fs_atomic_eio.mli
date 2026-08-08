(** Atomic file save for Eio paths — unique tmp + fsync + rename. *)

(** [save_atomic ~dir ~name content] writes [content] to the file
    [dir / name] atomically.

    Creates a writer-unique tmp file in [dir], writes and fsyncs it,
    then renames into place. Concurrent calls with the same [name]
    never share a tmp path, so [rename] cannot race against a sibling
    writer's [rename] (downstream #9780).

    Fsync of tmp and parent directory is best-effort: failures are
    silently tolerated for filesystems that reject fsync (tmpfs on
    some kernels, SMB). Where supported, fsync closes the crash
    window where [rename] succeeds but is not yet durable
    (downstream #9749).

    Returns [Error] via [Fs_result.io_error_of_exn] for any I/O,
    Eio, or Unix error. Re-raises [Eio.Cancel.Cancelled] after
    cleaning up the tmp file. *)
val save_atomic
  :  dir:Eio.Fs.dir_ty Eio.Path.t
  -> name:string
  -> string
  -> (unit, Error.sdk_error) result
