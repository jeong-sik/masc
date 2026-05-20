val disposition_fields_json :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> Yojson.Safe.t

val normalize_receipt_projection_json : Yojson.Safe.t -> Yojson.Safe.t

val snapshot_json :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> Yojson.Safe.t

val summary_json :
  config:Coord.config -> meta:Keeper_types.keeper_meta -> Yojson.Safe.t
