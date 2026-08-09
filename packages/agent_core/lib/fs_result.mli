(** Result-based filesystem operations.

    All functions return [('a, Error.t) result] instead of raising.
    Catches [Eio.Io], [Unix.Unix_error], [Sys_error], and [Failure].
    Non-recoverable exceptions (e.g. [Out_of_memory]) are re-raised.

    @raises only truly non-recoverable exceptions

    @stability Evolving
    @since 0.93.1 *)

(** {1 Core I/O} *)

(** Read entire file contents. *)
val read_file : string -> (string, Error.t) result

(** Write file atomically via .tmp + rename. Creates parent dirs. *)
val write_file : string -> string -> (unit, Error.t) result

(** Append content to file. Creates parent dirs if needed.
    The file is created with mode [0o600] (owner read/write only). *)
val append_file : string -> string -> (unit, Error.t) result

(** Like {!write_file} but guarantees owner-only ([0o600]) permissions using
    [O_CREAT|O_EXCL] and an atomic rename.  Use for files that may contain
    secrets or sensitive session data. *)
val write_file_secret : string -> string -> (unit, Error.t) result

(** {1 Directory operations} *)

(** Ensure directory exists (recursive).
    Returns [Error] if [path] is empty, any existing path component is not a
    directory, or a directory creation syscall fails. *)
val ensure_dir : string -> (unit, Error.t) result

(** List directory entries. *)
val read_dir : string -> (string list, Error.t) result

(** {1 Queries} *)

(** Check if path exists as a regular file. *)
val file_exists : string -> bool

(** {1 Deletion} *)

(** Remove a file. Returns [Ok ()] if file does not exist. *)
val remove_file : string -> (unit, Error.t) result

(** {1 Utilities} *)

(** Convert I/O exceptions to [Error.t].
    Re-raises non-recoverable exceptions.
    Extracted from checkpoint_store.ml for reuse. *)
val io_error_of_exn : op:string -> path:string -> exn -> (_, Error.t) result
