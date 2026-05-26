(** MASC-owned catalog of OAS risk contracts.

    OAS owns the generic {!Masc_mcp_cdal_runtime.Risk_contract.t} carrier and proof
    verification primitives. MASC owns these product-specific contract names,
    invariant strings, and operational meaning. *)

type contract_spec =
  { name : string
  ; description : string
  ; invariants : string list
  ; requested_execution_mode : Masc_mcp_cdal_runtime.Execution_mode.t
  ; risk_class : Masc_mcp_cdal_runtime.Risk_class.t
  ; allowed_mutations : string list
  ; review_requirement : string option
  }

val cascade_critical : contract_spec
val keeper_lifecycle : contract_spec
val dashboard_telemetry : contract_spec
val all : contract_spec list
val find : string -> contract_spec option
(** Build typed eval criteria for the contract catalog spec.
    Returns [Criteria.Contract_catalog_invariants]; the wire JSON layout is
    preserved from the pre-RFC-0109 shape. *)
val eval_criteria : contract_spec -> Masc_mcp_cdal_runtime.Criteria.t
val to_risk_contract : contract_spec -> Masc_mcp_cdal_runtime.Risk_contract.t
