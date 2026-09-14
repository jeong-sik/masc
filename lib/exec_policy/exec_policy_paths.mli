(** Filesystem path normalization and allowlist checks for exec policy. *)

val resolve_path : ?base_dir:string -> string -> string

val is_within_dir : dir:string -> string -> bool
(** Whether a resolved path is [dir] itself or a descendant of it. Both
    arguments must already have come through {!resolve_path}: this compares
    text, so an unresolved [..] or a symlink would walk out of [dir] without
    the comparison noticing. *)
val validate_path :
  ?workdir:string -> string -> bool
(** Resolve symlinks and validate only objective cwd/host-sandbox containment.
    No caller identity or product metadata is accepted at this boundary. *)
