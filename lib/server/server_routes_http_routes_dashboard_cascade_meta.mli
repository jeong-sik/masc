(** Cascade-name persistence helper for dashboard routes. *)

val sync_keeper_cascade_meta :
  config:Coord.config ->
  name:string ->
  cascade_name:string ->
  (bool, string) result
(** Persist a keeper cascade-name update to TOML and the in-memory registry. *)
