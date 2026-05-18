type keeper_context_snapshot =
  { context_ratio : float option
  ; context_tokens : int option
  ; context_max : int option
  ; context_source : string option
  }

val resolved_context_budget_of_meta : Keeper_types.keeper_meta -> int option
val compute_context_ratio : Keeper_types.keeper_meta -> float option
val keeper_context_snapshot_is_empty : keeper_context_snapshot -> bool
val keeper_context_snapshot_from_metrics_json : Yojson.Safe.t -> keeper_context_snapshot option
val latest_keeper_context_snapshot_from_files : Coord.config -> string -> keeper_context_snapshot option
val fallback_keeper_context_snapshot : Keeper_types.keeper_meta -> keeper_context_snapshot
val keeper_context_snapshot_of_meta : Coord.config -> Keeper_types.keeper_meta -> keeper_context_snapshot
val keeper_context_snapshot_fields : keeper_context_snapshot -> (string * Yojson.Safe.t) list
