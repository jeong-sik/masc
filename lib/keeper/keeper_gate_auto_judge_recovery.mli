(** Auto Judge after a restart and on operator request: the work a persisted
    pending approval still needs, the reclaim of an orphaned start
    reservation, the resume of the persisted judges of a workspace, the
    operator retry of a blocked judge and the operator recovery sweep.
    [Keeper_gate] includes this module. *)

open Keeper_gate_types
open Keeper_gate_auto_judge_queue

val retry_blocked_auto_judge :
  base_path:string ->
  requested_by:string ->
  expected_input_hash:string ->
  expected_sequence:int ->
  expected_exact_attempt:Keeper_approval_queue_rules_types.exact_attempt_state ->
  expected_disposition:Keeper_approval_queue_rules_types.summary_attempt_disposition ->
  string -> (unit, string) result

val retry_blocked_auto_judge_typed :
  base_path:string ->
  requested_by:string ->
  expected_input_hash:string ->
  expected_sequence:int ->
  expected_exact_attempt:Keeper_approval_queue_rules_types.exact_attempt_state ->
  expected_disposition:Keeper_approval_queue_rules_types.summary_attempt_disposition ->
  string ->
  (unit, auto_judge_retry_error) result

val resume_persisted_auto_judges_with :
  complete_summary_exact_attempt:(id:string ->
                                  input_hash:string ->
                                  sequence:int ->
                                  slot_id:string ->
                                  call_id:string ->
                                  plan_fingerprint:string ->
                                  request_body_sha256:string ->
                                  summary:Keeper_approval_queue_rules_types.hitl_context_summary ->
                                  (Keeper_approval_queue_result.exact_attempt_transition,
                                   Keeper_approval_queue_result.exact_attempt_error)
                                  result) ->
  base_path:string -> auto_judge_resume_report

val resume_persisted_auto_judges :
  base_path:string -> auto_judge_resume_report

type operator_recovery_report =
  { started_ids : string list
  ; queued : int
  ; failures : auto_judge_owner_failure list
  ; blockers : auto_judge_owner_blocker list
  }

val request_operator_auto_judge_recovery :
  base_path:string -> (operator_recovery_report, string) result
