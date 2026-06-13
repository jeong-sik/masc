(** Filesystem path normalization and allowlist checks for exec policy. *)

val normalize_path : ?base_dir:string -> string -> string
val resolve_path : ?base_dir:string -> string -> string
val is_within_dir : dir:string -> string -> bool

val keeper_registered_repo_path_allowed :
  ?keeper_id:string -> ?base_path:string -> string -> bool

val validate_path :
  ?keeper_id:string -> ?base_path:string -> ?workdir:string -> string -> bool
