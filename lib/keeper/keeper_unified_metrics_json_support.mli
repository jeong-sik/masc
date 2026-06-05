(** JSON helper layer for {!Keeper_unified_metrics}. *)

val decision_id :
  meta:Keeper_meta_contract.keeper_meta -> ts:float -> suffix_seed:string -> string

val tool_call_detail_to_json :
  Keeper_agent_run.tool_call_detail -> Yojson.Safe.t

val provider_context_json :
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t

val redacted_runtime_observation_to_json :
  Runtime_observation.runtime_observation -> Yojson.Safe.t

val tool_surface_json :
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t
