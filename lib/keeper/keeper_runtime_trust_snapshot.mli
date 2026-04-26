val disposition_fields_json
  :  config:Coord.config
  -> meta:Keeper_types.keeper_meta
  -> Yojson.Safe.t

val snapshot_json : config:Coord.config -> meta:Keeper_types.keeper_meta -> Yojson.Safe.t
