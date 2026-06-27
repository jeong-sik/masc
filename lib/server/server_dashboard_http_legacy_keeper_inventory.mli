(** Read-only inventory for legacy [.masc/keepers].

    This does not delete or move files. It reports bounded classification and a
    dry-run cleanup plan so operators can decide ownership before any destructive
    action. *)

val default_max_depth : int
val default_max_entries : int

val legacy_keeper_inventory_http_json :
  base_path:string ->
  ?max_depth:int ->
  ?max_entries:int ->
  unit ->
  Yojson.Safe.t
