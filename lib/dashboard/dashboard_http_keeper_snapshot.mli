(** Dashboard_http_keeper_snapshot — per-keeper snapshot and config rendering.

    Extracted from [dashboard_http_keeper.ml] during godfile decomposition.
    Internal helpers ([recent_keeper_metric_jsons], [recent_token_spend_json],
    [latest_tool_call_json]) stay private; only the external surface is exposed. *)

val keeper_bdi_snapshot_json :
  Coord.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t

val keeper_config_json :
  Coord.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t

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
