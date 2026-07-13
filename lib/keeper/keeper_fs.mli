(** Keeper_fs — Centralized keeper filesystem operations.

    Provides atomic file writes (write-to-temp + rename) and
    fiber-safe directory creation with caching.

    @since 2.162.0 — #3721 keeper stabilization *)

(** {1 Directory Management} *)

(** Ensure [path] exists, creating it recursively if needed.
    Fiber-safe: protected by Eio.Mutex. Returns [path] for chaining. *)
val ensure_dir : string -> string

(** Remove [path] from the directory cache.
    Call after external deletion or move. *)
val invalidate_dir : string -> unit

(** Clear the entire directory cache. Useful in tests. *)
val clear_dir_cache : unit -> unit

(** {1 Atomic File Writes} *)

(** Atomically save [content] to [path] via write-to-temp + rename.
    Returns [Error msg] on I/O failure. Cancellation still re-raises. *)
val save_atomic : string -> string -> (unit, string) result

(** Atomically save a JSON value as pretty-printed JSON.
    Returns [Error msg] on I/O failure. Cancellation still re-raises. *)
val save_json_atomic : string -> Yojson.Safe.t -> (unit, string) result

type durable_write_stage =
  | Directory_prepare
  | Temp_file_create
  | Payload_write
  | Payload_fsync
  | Temp_file_close
  | Atomic_rename
  | Parent_directory_fsync_after_rename

type durable_write_error =
  { renamed : bool
  ; stage : durable_write_stage
  ; reason : string
  }

(** Strict durable atomic JSON write. Unlike the compatibility
    [save_json_atomic] boundary, parent-directory fsync failure is returned as
    an error and never downgraded to success. *)
val save_json_durable_atomic :
  string -> Yojson.Safe.t -> (unit, durable_write_error) result

val durable_write_error_to_string : durable_write_error -> string

type durable_remove_stage =
  | Unlink
  | Parent_directory_fsync

type durable_remove_error =
  { removed : bool
  ; failure : durable_remove_stage * string
  }

(** Idempotently unlink [path] and fsync its parent directory. *)
val remove_file_durable : string -> (unit, durable_remove_error) result
val durable_remove_error_to_string : durable_remove_error -> string

module For_testing : sig
  (** Deterministic fault boundary. [before_stage] runs immediately before the
      named filesystem operation and may raise to verify the typed contract. *)
  val save_json_durable_atomic
    :  before_stage:(durable_write_stage -> unit)
    -> string
    -> Yojson.Safe.t
    -> (unit, durable_write_error) result

  val remove_file_durable
    :  before_stage:(durable_remove_stage -> unit)
    -> string
    -> (unit, durable_remove_error) result
end

(** {1 Standard Keeper Paths} *)

(** [.masc/keepers/] directory. *)
val keeper_dir : Workspace.config -> string

(** [.masc/traces/] directory. *)
val session_base_dir : Workspace.config -> string

(** [.masc/traces/<trace_id>/] directory. *)
val keeper_session_dir : Workspace.config -> string -> string
