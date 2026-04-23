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
    Returns [Error _] on I/O failure. *)
val save_atomic : string -> string -> (unit, string) result

(** Atomically save a JSON value as pretty-printed JSON.
    Returns [Error _] on I/O failure. *)
val save_json_atomic : string -> Yojson.Safe.t -> (unit, string) result

(** {1 Standard Keeper Paths} *)

(** [.masc/keepers/] directory. *)
val keeper_dir : Coord.config -> string

(** [.masc/traces/] directory. *)
val session_base_dir : Coord.config -> string

(** [.masc/traces/<trace_id>/] directory. *)
val keeper_session_dir : Coord.config -> string -> string
