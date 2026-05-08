(** Cdal_runtime — Skeleton placeholder for the OAS CDAL runtime sublibrary.

    This module exists solely to give the [masc_mcp.cdal_runtime] dune library
    one buildable compilation unit while RFC-OAS-011 MM-1 is in flight.

    No public API will live in this module. MM-2 leaf-first batches replace
    this placeholder with the migrated CDAL runtime modules in the order:

      B1 (pure leaves):  execution_mode, effect_evidence, guardrail_llm
      B2 (low-deps):     risk_class, verified_output, conformance
      B3 (mid-deps):     risk_contract, cdal_proof, mode_resolver, cognitive_event
      B4 (high-deps):    proof_capture, proof_store, mode_enforcer,
                         contract_runner, direct_evidence
      B5 (top-deps):     audit, autonomy_*, sessions_proof, etc.

    @rfc RFC-OAS-011 *)

let placeholder_marker = "RFC-OAS-011 MM-1 skeleton"
