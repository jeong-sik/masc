val enrich_composite_snapshot_json :
  config:Workspace.config ->
  Keeper_registry.registry_entry ->
  Yojson.Safe.t ->
  Yojson.Safe.t

val dashboard_keeper_composite_json :
  config:Workspace.config ->
  Keeper_registry.registry_entry ->
  Yojson.Safe.t

val dashboard_fleet_composite_json :
  config:Workspace.config -> unit -> Yojson.Safe.t
