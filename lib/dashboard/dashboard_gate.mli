(** Read-only dashboard projection of the non-hierarchical Keeper Gate. *)

val dashboard_json :
  base_path:string ->
  limit:int ->
  offset:int ->
  status_filter:'a ->
  Yojson.Safe.t
