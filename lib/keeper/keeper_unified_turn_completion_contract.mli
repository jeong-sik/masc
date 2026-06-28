(** Completion-contract latch recovery for the unified keeper turn.

    Parallel of {!Keeper_unified_turn_no_progress} for the
    completion-contract violation branch. See [.ml] for the
    rationale (RFC-0047 §3.2 / plan hypothesis B: "resume doesn't
    stick" symptom).

    This module is purely additive — no new pause or escalation
    behavior. *)

(** Clear the completion-contract latch on operator resume.

    Resets [Keeper_registry.last_failure_reason] (when it is the typed
    [Completion_contract_violation] failure, plus the legacy provider-runtime
    code kept for on-disk compatibility) and the
    [Keeper_meta_contract.runtime.last_blocker] (when its klass is
    [Completion_contract_violation]). Other resume state —
    [paused], [turn_consecutive_failures] — is owned by
    [Keeper_supervisor_resume_reconcile_gate] and is not touched here.

    Returns the (possibly mutated) meta. *)
val failure_reason_code : string
(** Legacy provider-runtime failure code still cleared for on-disk compatibility. *)

val clear_for_operator_resume
  :  base_path:string
  -> Keeper_meta_contract.keeper_meta
  -> Keeper_meta_contract.keeper_meta
