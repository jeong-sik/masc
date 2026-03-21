(** Tool_mitosis_utils — Thin wrapper delegating to OAS Checkpoint_validation.

    DNA validation, continuity regression, and text utilities are now
    implemented in OAS (agent_sdk.Checkpoint_validation). This module
    re-exports them for MASC callers.

    @since 2.126.0 *)

module CV = Agent_sdk.Checkpoint_validation

let contains_substring_ci = CV.contains_substring_ci

let validate_dna = CV.validate_dna

let token_overlap_ratio = CV.token_overlap_ratio

let extract_prefixed_line = CV.extract_prefixed_line

let continuity_regression_check = CV.continuity_check
