(** JSON helper layer for {!Keeper_unified_metrics}. *)

val decision_id :
  meta:Keeper_types.keeper_meta -> ts:float -> suffix_seed:string -> string

val tool_call_detail_to_json :
  Keeper_agent_run.tool_call_detail -> Yojson.Safe.t

val provider_context_json :
  meta:Keeper_types.keeper_meta ->
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t

val redacted_cascade_observation_to_json :
  Cascade_legacy_runner.cascade_observation -> Yojson.Safe.t

val tool_contract_json :
  tool_call_count:int ->
  tools_used:string list ->
  Keeper_agent_run.run_result option ->
  Yojson.Safe.t

val cdal_raw_evidence_ref_count :
  Masc_mcp_cdal_runtime.Cdal_proof.t -> int

val cdal_violation_ref_count :
  Masc_mcp_cdal_runtime.Cdal_proof.t -> int
