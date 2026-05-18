(** Path normalization and allowlist checks for worker dev tools. *)

val normalize_path : ?base_dir:string -> string -> string
val resolve_path : ?base_dir:string -> string -> string

val validate_path :
  ?keeper_id:string ->
  ?base_path:string ->
  ?workdir:string ->
  string ->
  bool
