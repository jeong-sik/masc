(** Shared storage authority for the official-client runtime and its outbox.
    Paths retain the same BasePath representation as {!Common}; no filesystem
    lookup or additional canonicalization is performed. *)

val state_dir : base_path:string -> keeper_name:string -> (string, string) result
(** Existing portable Keeper-name admission and runtime state directory. *)

val outbox_dir : base_path:string -> keeper_name:string -> (string, string) result

type outbox_source
(** One exact direct file path in a Keeper's official-client outbox directory.
    Filesystem ownership and symlink admission remain the scanner's authority;
    this token does not validate JSON or its filename digest. *)

val outbox_source : base_path:string -> path:string -> outbox_source option
(** [None] outside the exact directory produced by {!outbox_dir}, including
    nonportable Keeper names or extra path components. *)

val outbox_source_path : outbox_source -> string
