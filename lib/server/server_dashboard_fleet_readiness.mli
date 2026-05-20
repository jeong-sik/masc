(** Fleet work-discovery readiness JSON builders for the dashboard
    composite endpoint. *)

val keeper_activation_readiness_json : Keeper_types.keeper_meta -> Yojson.Safe.t
val task_is_unclaimed_todo : Masc_domain.task -> bool
val unclaimed_todo_count : config:Coord.config -> int

val fleet_work_discovery_readiness_json
  :  todo_unclaimed_count:int
  -> Keeper_registry.registry_entry list
  -> Yojson.Safe.t
