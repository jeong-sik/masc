val keeper_bdi_snapshot_json :
  Coord.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t
