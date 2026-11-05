val keeper_costs_max_window_minutes : int
(** The longest [window] GET /api/v1/dashboard/keeper-costs accepts. *)

val keeper_costs_window_of_query : string option -> (int, string) result
(** The [window] query parameter: absent is the default (the maximum); a
    value that is not an integer in [1, keeper_costs_max_window_minutes] is
    an error, never clamped. *)

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  now_ts:float ->
  Yojson.Safe.t

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
