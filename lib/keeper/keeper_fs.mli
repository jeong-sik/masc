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
  | Payload_encode
  | Temp_file_create
  | Payload_write
  | Payload_fsync
  | Temp_file_close
  | Atomic_rename
  | Parent_directory_fsync_after_rename
  | Temp_directory_fsync_after_rename

type directory_chain_error =
  | Non_directory_ancestor of { path : string }
  | Outside_ownership_root of
      { ownership_root : string
      ; path : string
      }
  | Missing_root of { path : string }
  | Creation_not_observed of { path : string }

type durable_write_failure =
  | Directory_chain_failed of directory_chain_error
  | Operation_failed of string

type durable_write_error =
  { renamed : bool
  ; stage : durable_write_stage
  ; failure : durable_write_failure
  }

(** Strict durable atomic JSON write. Unlike the compatibility
    [save_json_atomic] boundary, parent-directory fsync failure is returned as
    an error and never downgraded to success. When [temp_dir] differs from the
    target parent, the rename is anchored by fsyncing both directories. When
    [ownership_root] is supplied, both directory chains must be lexically
    contained below it and symbolic-link components are rejected. The caller
    keeps that subtree process-owned while the write runs because OCaml 5.4
    has no portable dirfd-relative rename API. *)
val save_json_durable_atomic
  :  ?ownership_root:string
  -> ?temp_dir:string
  -> string
  -> Yojson.Safe.t
  -> (unit, durable_write_error) result

(** Strict durable JSON write whose value is constructed and encoded through
    the process executor pool when it is available. [json_source] must be a
    pure closure. This keeps large queue snapshots from monopolizing the Eio
    scheduler while preserving the same atomic publication and ownership
    contract; blocking filesystem operations still run in a systhread. *)
val save_json_durable_atomic_from
  :  ?ownership_root:string
  -> ?temp_dir:string
  -> string
  -> (unit -> Yojson.Safe.t)
  -> (unit, durable_write_error) result

val durable_write_error_to_string : durable_write_error -> string

type durable_remove_stage =
  | Unlink
  | Parent_directory_fsync

type durable_remove_error =
  { removed : bool
  ; failure : durable_remove_stage * string
  }

(** Idempotently unlink [path] and fsync its parent directory. When
    [ownership_root] is supplied, the parent chain is inspected without
    following symbolic links immediately before the mutation. *)
val remove_file_durable
  :  ?ownership_root:string
  -> string
  -> (unit, durable_remove_error) result
val durable_remove_error_to_string : durable_remove_error -> string

module For_testing : sig
  (** Deterministic fault boundary. [before_stage] runs immediately before the
      named filesystem operation. [before_directory_fsync] runs immediately
      before anchoring one directory component in the durability systhread.
      Either may raise to verify the typed contract and retry behavior. *)
  val save_json_durable_atomic
    :  before_stage:(durable_write_stage -> unit)
    -> ?before_directory_fsync:(string -> unit)
    -> ?ownership_root:string
    -> ?temp_dir:string
    -> string
    -> Yojson.Safe.t
    -> (unit, durable_write_error) result

  val save_json_durable_atomic_from
    :  before_stage:(durable_write_stage -> unit)
    -> ?before_directory_fsync:(string -> unit)
    -> ?ownership_root:string
    -> ?temp_dir:string
    -> string
    -> (unit -> Yojson.Safe.t)
    -> (unit, durable_write_error) result

  val remove_file_durable
    :  before_stage:(durable_remove_stage -> unit)
    -> ?ownership_root:string
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
