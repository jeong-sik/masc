(** Persistent keeper-agent rows for the operator snapshot. *)

val persistent_agents_json :
  keeper_names:string list ->
  keeper_rows:Yojson.Safe.t list ->
  Yojson.Safe.t
(** Build the persistent keeper-agent `{ count; items }` JSON object from the
    Keeper rows of the snapshot: the rows of the Keepers in [keeper_names],
    with the fields the operator snapshot publishes. Reads nothing. *)
