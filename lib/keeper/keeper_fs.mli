(** Keeper_fs — Centralized keeper filesystem operations.

    Provides atomic file writes (write-to-temp + rename) and
    fiber-safe directory creation with caching.

    @since 2.162.0 — #3721 keeper stabilization *)

(** {1 Directory Management} *)

(** Ensure [path] exists, creating it recursively if needed. A successful path
    is cached for the process lifetime: cache hits perform no stat or mkdir.
    Cache misses synchronize only with the same path, so one Keeper's directory
    fsync cannot serialize unrelated Keeper lanes. Returns [path] for chaining. *)
val ensure_dir : string -> string

(** Remove [path] and every cached descendant from the directory cache. Call
    after external deletion or move so a later child write recreates its full
    directory chain instead of trusting stale process-local ancestry. *)
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

(** {1 Standard Keeper Paths} *)

(** [.masc/keepers/] directory. *)
val keeper_dir : Workspace.config -> string

(** [.masc/traces/] directory. *)
val session_base_dir : Workspace.config -> string

(** [.masc/traces/<trace_id>/] directory. *)
val keeper_session_dir : Workspace.config -> string -> string
