(** Filesystem ownership and regular-file checks for the chat queue database. *)

type regular_path_observation =
  | Path_absent
  | Regular_path of Unix.stats

val inspect_regular_or_absent :
  string -> (regular_path_observation, string) result

val same_regular_identity : Unix.stats -> Unix.stats -> bool

val validate_owned_parent :
  ownership_root:string -> string -> (unit, string) result

val prepare_database_parent :
  ownership_root:string ->
  path:string ->
  create_if_missing:bool ->
  (unit, string) result

val validate_database_paths :
  ownership_root:string ->
  string ->
  (regular_path_observation, string) result
