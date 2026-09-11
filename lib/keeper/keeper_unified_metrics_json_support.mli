(** JSON helper layer for {!Keeper_unified_metrics}. *)

val decision_id :
  meta:Keeper_meta_contract.keeper_meta -> ts:float -> suffix_seed:string -> string

val tool_call_detail_to_json :
  Keeper_agent_run.tool_call_detail -> Yojson.Safe.t

val provider_context_json :
  meta:Keeper_meta_contract.keeper_meta ->
  ?executed_runtime_id:string ->
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t
(** [runtime_id] names the lane this turn was budgeted under.
    [executed_runtime_id] names the candidate that actually answered, which
    sticky lane ordering can make a different runtime. Two questions, two
    fields: reading the lane as the answerer filed 162 payment-required
    errors against a provider that was serving normally (masc#35043). Emitted
    as [null] when no candidate reported in. *)

val redacted_runtime_observation_to_json :
  Runtime_observation.runtime_observation -> Yojson.Safe.t

val tool_surface_json :
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t
