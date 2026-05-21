(** Persistent keeper-agent rows for the operator snapshot. *)

val persistent_agents_json :
  ?keeper_names:string list ->
  ?keeper_rows:Yojson.Safe.t list ->
  Coord.config ->
  Yojson.Safe.t
(** Build the persistent keeper-agent `{ count; items }` JSON object. *)
