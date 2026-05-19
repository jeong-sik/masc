val keeper_cost_aggregates_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t

val keeper_decisions_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_decisions_log_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_memory_log_json :
  config:Coord.config ->
  keepers:Keeper_types.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
