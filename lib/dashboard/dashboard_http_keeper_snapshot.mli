(** Dashboard_http_keeper_snapshot — per-keeper config rendering and K2 feed
    delegations.

    Extracted from [dashboard_http_keeper.ml] during godfile decomposition. *)

val keeper_config_json :
  Workspace.config ->
  string ->
  [ `OK | `Not_found ] * Yojson.Safe.t

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_decisions_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_memory_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
