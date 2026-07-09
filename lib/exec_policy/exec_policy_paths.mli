(** Filesystem path normalization and allowlist checks for exec policy. *)

val normalize_path : ?base_dir:string -> string -> string
val resolve_path : ?base_dir:string -> string -> string
val is_within_dir : dir:string -> string -> bool

val keeper_registered_repo_path_allowed :
  ?keeper_id:string -> ?base_path:string -> string -> bool
(** RFC-0324 B-2': for paths inside a keeper playground [repos/<segment>]
    lane the decision is filesystem truth — the clone directory must exist
    (fail-closed on missing/unstatable). Catalog membership no longer gates
    playground exec paths; it still gates non-playground paths that resolve
    via a catalog repo's [local_path]. Paths outside any repo resolution
    return [false] (the playground boundary is enforced upstream by the
    resolution itself). *)

val validate_path :
  ?keeper_id:string -> ?base_path:string -> ?workdir:string -> string -> bool
