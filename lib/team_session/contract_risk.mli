(** Contract_risk — Derive OAS execution risk_class from MASC delivery_contract.

    Uses the three-axis model from the CDAL RFC:
    blast_radius x irreversibility x recovery_cost → Risk_class.t *)

type blast_radius = Small | Medium | Large
type irreversibility = Reversible | Partial | Irreversible
type recovery_cost = Rc_low | Rc_medium | Rc_high

type risk_axes = {
  blast_radius : blast_radius;
  irreversibility : irreversibility;
  recovery_cost : recovery_cost;
}

val assess :
  execution_scope:Team_session_types.execution_scope option ->
  delivery_contract:Team_session_types.delivery_contract ->
  tool_names:string list ->
  risk_axes

val to_risk_class : risk_axes -> Agent_sdk.Risk_class.t

val of_delivery_contract :
  execution_scope:Team_session_types.execution_scope option ->
  delivery_contract:Team_session_types.delivery_contract ->
  tool_names:string list ->
  Agent_sdk.Risk_class.t
