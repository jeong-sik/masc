(** Cdal_judge -- Phase 1A contract judge with 4 active checks.

    Evaluates a loaded proof bundle against its contract constraints:
    execution mode propagation and escalation, risk class match,
    contract snapshot integrity, and required artifact presence.

    @since CDAL Phase 1A *)

(** Evaluate all 4 checks and derive run-level verdict. *)
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
