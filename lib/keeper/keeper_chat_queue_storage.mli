(** Private storage boundary for the durable Keeper chat queue. *)

val error : operation:string -> Sqlite3.db -> Sqlite3.Rc.t -> string

val exec :
  Sqlite3.db -> operation:string -> string -> (unit, string) result

val bind :
  Sqlite3.db ->
  Sqlite3.stmt ->
  operation:string ->
  int ->
  Sqlite3.Data.t ->
  (unit, string) result

val bind_text :
  Sqlite3.db ->
  Sqlite3.stmt ->
  operation:string ->
  int ->
  string ->
  (unit, string) result

val bind_int64 :
  Sqlite3.db ->
  Sqlite3.stmt ->
  operation:string ->
  int ->
  int64 ->
  (unit, string) result

val expect_done :
  Sqlite3.db -> Sqlite3.stmt -> operation:string -> (unit, string) result

val finalize : Sqlite3.db -> Sqlite3.stmt -> (unit, string) result

val combine_cleanup_error :
  ('a, string) result -> (unit, string) result -> ('a, string) result

val with_statement :
  Sqlite3.db ->
  string ->
  (Sqlite3.stmt -> ('a, string) result) ->
  ('a, string) result

val single_int64 :
  Sqlite3.db -> operation:string -> string -> (int64, string) result

val single_text :
  Sqlite3.db -> operation:string -> string -> (string, string) result

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
