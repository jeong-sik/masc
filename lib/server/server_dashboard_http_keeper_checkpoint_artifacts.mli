(** Keeper checkpoint inventory and linked-artifact JSON helpers. *)

val keeper_checkpoint_inventory_json :
  Coord.config -> string -> [ `OK | `Not_found ] * Yojson.Safe.t

val linked_artifact_json : kind:string -> string -> Yojson.Safe.t
