(** Contract_composer — Translate MASC delivery_contract to OAS Risk_contract.t.

    Maps session-level delivery_contract fields onto per-run risk_contract:
    - acceptance_checks → eval_criteria.success_criteria
    - required_artifacts → eval_criteria.required_evidence
    - repair_budget → requested_execution_mode
    - tool set → allowed_mutations + risk_class *)

val compose :
  execution_scope:Team_session_types.execution_scope option ->
  delivery_contract:Team_session_types.delivery_contract ->
  tool_names:string list ->
  Agent_sdk.Risk_contract.t
