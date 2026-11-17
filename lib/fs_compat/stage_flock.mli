(** Open-file-description [flock(2)] liveness probes for staging files. *)

val try_lock_exclusive_fd : Unix.file_descr -> bool
(** Acquire a non-blocking exclusive [flock] on [fd]. *)

val lock_exclusive_fd : Unix.file_descr -> path:string -> unit
(** Acquire a non-blocking exclusive [flock] on [fd], raising [Unix.Unix_error]
    with [path] when the OS refuses or contends the open-file-description lock. *)

val is_path_flocked : string -> bool
(** [true] when [path] is an existing regular file with an active [flock]
    held on another open-file description (in this or another process).
    Probing never releases an existing holder's lock. *)
