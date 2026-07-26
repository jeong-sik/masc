(** Persistent keeper-agent rows for the operator snapshot. *)

val persistent_agents_json :
  discovery:Keeper_meta_store.current_meta_discovery ->
  keeper_rows:Yojson.Safe.t list ->
  Yojson.Safe.t
(** Build the persistent keeper-agent `{ count; items; unavailable }` JSON
    object. Unavailable current metadata is never synthesized as a keeper row. *)
