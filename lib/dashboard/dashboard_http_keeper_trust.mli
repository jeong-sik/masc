(** Keeper trust projection for the dashboard. *)

val keeper_trust_json :
  ?include_receipt:bool ->
  Coord.config ->
  Keeper_types.keeper_meta ->
  Yojson.Safe.t
