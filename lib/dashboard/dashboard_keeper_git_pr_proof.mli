(** Docker-backed keeper git-to-PR workflow proof read model. *)

val json :
  ?window_hours:float ->
  n:int ->
  keeper_names:string list ->
  unit ->
  Yojson.Safe.t
