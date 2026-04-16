(** Cdal_judge -- Phase 1A contract judge with 5 active checks.

    Evaluates a loaded proof bundle against its contract constraints:
    execution mode propagation and escalation, risk class match,
    contract snapshot integrity, required artifact presence, and
    review-requirement bridgeability.

    @since CDAL Phase 1A *)

(** Evaluate all 5 checks and derive run-level verdict. *)
val judge : Cdal_loader.loaded_bundle -> Cdal_types.contract_verdict

(** {2 Individual checks (exposed for testing)} *)

(** Check execution mode propagation and no-upward-escalation. *)
val check_execution_mode : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check risk class matches contract constraint. *)
val check_risk_class : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check proof contract_id matches recomputed hash. *)
val check_contract_snapshot : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check required artifacts are present (always Satisfied post-load). *)
val check_required_artifact : Cdal_loader.loaded_bundle -> Cdal_types.check_result

(** Check review_requirement is either absent or routed to the verification FSM.
    Current OAS v1 evidence is warning-only, so review requirements remain
    [Inconclusive] until explicit verification occurs downstream. *)
val check_review_requirement : Cdal_loader.loaded_bundle -> Cdal_types.check_result
