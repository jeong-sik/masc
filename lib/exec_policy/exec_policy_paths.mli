(** Filesystem path normalization and allowlist checks for exec policy. *)

val normalize_path : ?base_dir:string -> string -> string
val resolve_path : ?base_dir:string -> string -> string
val is_within_dir : dir:string -> string -> bool

val validate_path :
  ?workdir:string -> string -> bool
(** Resolve symlinks and validate only objective cwd/host-sandbox containment.
    No caller identity or product metadata is accepted at this boundary. *)
