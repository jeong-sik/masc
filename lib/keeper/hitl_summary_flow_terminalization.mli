(** Judging what the exact-output flow returned: matching the receipt and
    provenance of a summary against the prepared flow, validating the summary,
    delivering a valid one, and settling the entry when the semantic checks
    or the candidates run out or the flow fails. [Hitl_summary_worker]
    includes this module. *)

open Keeper_approval_queue_rules_types
open Hitl_summary_flow_prepare
open Hitl_summary_exact_queue

type semantic_rejection =
  | Semantic_provenance_mismatch
  | Semantic_domain_invalid of string

val validate_success :
  prepared_flow ->
  Agent_core.Exact_output.flow_success ->
  (hitl_context_summary,
   semantic_rejection)
  Agent_core.Exact_output.semantic_verdict

val handle_validated_success :
  queue_ops:exact_queue_ops ->
  prepared_flow ->
  on_summary:(hitl_context_summary -> unit) ->
  Agent_core.Exact_output.flow_success ->
  hitl_context_summary -> unit

val last_semantic_rejection :
  semantic_rejection Agent_core.Exact_output.semantic_rejection_trace ->
  semantic_rejection Agent_core.Exact_output.semantic_rejection_receipt

val handle_semantic_exhaustion :
  queue_ops:exact_queue_ops ->
  prepared_flow ->
  semantic_rejection Agent_core.Exact_output.semantic_rejection_trace -> unit

val handle_flow_error :
  queue_ops:exact_queue_ops ->
  prepared_flow ->
  flow_callback_error
  Agent_core.Exact_output.flow_execution_error -> unit
