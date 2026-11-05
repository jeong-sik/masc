open Keeper_approval_queue_result
open Keeper_approval_queue_rules_types
module Exact_output = Agent_core.Exact_output
open Hitl_summary_flow_outcome
open Hitl_summary_flow_prepare
open Hitl_summary_exact_queue
open Hitl_summary_exact_settlement

let same_catalog_generation left right =
  String.equal
    (Exact_output.catalog_generation_fingerprint left)
    (Exact_output.catalog_generation_fingerprint right)
;;

let same_catalog_evidence left right =
  String.equal
    (Exact_output.catalog_evidence_sha256 left)
    (Exact_output.catalog_evidence_sha256 right)
;;

let same_target_identity left right =
  String.equal
    (Exact_output.target_identity_fingerprint left)
    (Exact_output.target_identity_fingerprint right)
;;

let receipt_matches
      (left : Exact_output.receipt)
      (right : Exact_output.receipt)
  =
  String.equal
    (left |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
    (right |> Exact_output.receipt_call_id |> Exact_output.call_id_to_string)
  && String.equal
       (Exact_output.receipt_plan_fingerprint left)
       (Exact_output.receipt_plan_fingerprint right)
  && String.equal
       (Exact_output.receipt_request_body_sha256 left)
       (Exact_output.receipt_request_body_sha256 right)
  && same_catalog_generation
       (Exact_output.receipt_catalog_generation left)
       (Exact_output.receipt_catalog_generation right)
  && same_catalog_evidence
       (Exact_output.receipt_catalog_evidence left)
       (Exact_output.receipt_catalog_evidence right)
  && same_target_identity
       (Exact_output.receipt_target_identity left)
       (Exact_output.receipt_target_identity right)
;;

let success_provenance_matches (flow_success : Exact_output.flow_success) =
  let candidate = Exact_output.flow_success_candidate flow_success in
  let identity = candidate.visit.identity in
  let success = Exact_output.flow_success_output flow_success in
  let provenance = success.provenance in
  String.equal
    (Exact_output.call_id_to_string success.call_id)
    (candidate.receipt
     |> Exact_output.receipt_call_id
     |> Exact_output.call_id_to_string)
  && receipt_matches candidate.receipt success.receipt
  && same_catalog_generation
       identity.catalog_generation
       (Exact_output.receipt_catalog_generation candidate.receipt)
  && same_catalog_evidence
       identity.catalog_evidence
       (Exact_output.receipt_catalog_evidence candidate.receipt)
  && same_target_identity
       identity.target_identity
       (Exact_output.receipt_target_identity candidate.receipt)
  && same_catalog_generation
       identity.catalog_generation
       (Exact_output.plan_provenance_catalog_generation provenance)
  && same_catalog_evidence
       identity.catalog_evidence
       (Exact_output.plan_provenance_catalog_evidence provenance)
  && same_target_identity
       identity.target_identity
       (Exact_output.plan_provenance_target_identity provenance)
;;

type semantic_rejection =
  | Semantic_provenance_mismatch
  | Semantic_domain_invalid of string

let validate_success (prepared : prepared_flow) flow_success =
  if not (success_provenance_matches flow_success)
  then Exact_output.Reject_and_advance Semantic_provenance_mismatch
  else
    let call_id =
      flow_success
      |> Exact_output.flow_success_candidate
      |> fun candidate -> candidate.receipt
      |> Exact_output.receipt_call_id
      |> Exact_output.call_id_to_string
    in
    let success = Exact_output.flow_success_output flow_success in
    match
      Hitl_summary_request.parse_summary
        ~generated_at:prepared.generated_at
        ~model_run_id:call_id
        success.output
    with
    | Error detail ->
      Exact_output.Reject_and_advance (Semantic_domain_invalid detail)
    | Ok summary -> Exact_output.Accept summary
;;

let handle_validated_success
      ~queue_ops
      (prepared : prepared_flow)
      ~on_summary
      (flow_success : Exact_output.flow_success)
      summary
  =
  let entry = prepared.entry in
  let candidate = Exact_output.flow_success_candidate flow_success in
  let identity = exact_identity_of_candidate candidate in
  match complete_exact_attempt queue_ops entry identity summary with
  | Ok { write_outcome = Fsync_completed; _ } ->
    record_outcome Ok_summary;
    on_summary summary
  | Ok { write_outcome = Visible_sync_unconfirmed detail; _ } ->
    record_outcome Terminal_sync_unconfirmed;
    signal_terminalization_persistence_failure
      entry
      "completion sync"
      detail
  | Error error when exact_attempt_source_resolved entry error ->
    record_outcome Source_resolved
  | Error (Exact_attempt_rejected rejection) ->
    raise (Exact_terminalization_rejected rejection)
  | Error (Exact_attempt_storage_error error) ->
    record_outcome Terminal_persistence_failure;
    log_exact_error
      entry
      "completion"
      (Keeper_approval_queue_result.storage_error_to_string error);
    quarantine_identity
      ~queue_ops
      entry
      identity
      Exact_terminal_persistence_failure
;;

let last_semantic_rejection
      (trace : semantic_rejection Exact_output.semantic_rejection_trace)
  =
  List.fold_left
    (fun _ rejection -> rejection)
    trace.first
    trace.rest
;;

let handle_semantic_exhaustion ~queue_ops (prepared : prepared_flow) trace =
  let rejection = last_semantic_rejection trace in
  let flow_success = rejection.transport_success in
  let candidate = Exact_output.flow_success_candidate flow_success in
  match rejection.rejection with
  | Semantic_provenance_mismatch ->
    record_outcome Provenance_mismatch;
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_flow_execution_failed
  | Semantic_domain_invalid detail ->
    record_outcome Domain_invalid_output;
    log_exact_error prepared.entry "domain validation" detail;
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_domain_invalid_output
;;

(* Five distinct outcomes settle as the same [Exact_flow_execution_failed]
   quarantine cause - attempt-allocation failure, measurement-allocation failure,
   candidate exhaustion, provider execution failure and provenance mismatch - and
   the durable row keeps only that label. An operator therefore reads "Auto Judge
   exact attempt quarantined: flow_execution_failed" with no way to tell a local
   context-capacity refusal from a provider outage, while the evidence payload
   each error carries is discarded at this boundary. Observed 2026-07-28: 25
   approvals quarantined under that one label, zero occurrences of the word in
   the system log, and no metrics endpoint listening to read the per-branch
   counter [record_outcome] already writes. Each branch logs its payload through
   the AGENT_CORE renderers so the branch and the slot it died on are
   recoverable. *)
let handle_flow_error ~queue_ops (prepared : prepared_flow) = function
  | Exact_output.Flow_attempt_already_started evidence ->
    record_outcome Attempt_replay;
    log_exact_error
      prepared.entry
      "attempt replay"
      (Exact_output.flow_evidence_to_string evidence);
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output flow attempt was replayed"
      ~cause:Exact_attempt_replay
  | Exact_output.Flow_attempt_start_failed { cause; evidence; _ } ->
    record_outcome Attempt_start_failed;
    let cause_detail =
      match cause with
      | Exact_output.Call_id_generation_failed detail -> detail
    in
    log_exact_error
      prepared.entry
      "candidate attempt allocation"
      (Printf.sprintf
         "%s (%s)"
         cause_detail
         (Exact_output.flow_evidence_to_string evidence));
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output candidate attempt allocation failed"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_measurement_start_failed { evidence; _ } ->
    record_outcome Measurement_start_failed;
    log_exact_error
      prepared.entry
      "measurement allocation"
      (Exact_output.flow_evidence_to_string evidence);
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output measurement allocation failed"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_candidates_exhausted { rejection; evidence } ->
    record_outcome Candidates_exhausted;
    log_exact_error
      prepared.entry
      "candidate exhaustion before dispatch"
      (Printf.sprintf
         "%s (%s)"
         (Exact_output.candidate_rejection_to_string rejection)
         (Exact_output.flow_evidence_to_string evidence));
    settle_current_or_signal
      ~queue_ops
      prepared.entry
      ~reason:"HITL exact-output candidates exhausted before dispatch"
      ~cause:Exact_flow_execution_failed
  | Exact_output.Flow_before_measurement_dispatch_callback_failed
      { cause; _ }
  | Exact_output.Flow_measurement_terminal_callback_failed
      { cause; _ } ->
    record_outcome Measurement_callback_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_before_dispatch_callback_failed { cause; _ } ->
    record_outcome Bind_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_before_advance_callback_failed { cause; _ } ->
    record_outcome Release_failed;
    (match flow_callback_rejection cause with
     | Some rejection -> raise (Exact_terminalization_rejected rejection)
     | None ->
       settle_current_or_signal
         ~queue_ops
         prepared.entry
         ~reason:(flow_callback_error_to_string cause)
         ~cause:Exact_terminal_persistence_failure)
  | Exact_output.Flow_exact_execution_failed { candidate; cause = _; evidence = _ }
    as error ->
    record_outcome Execution_failed;
    log_exact_error
      prepared.entry
      "exact execution"
      (Exact_output.flow_execution_error_to_string
         ~callback_error_to_string:flow_callback_error_to_string
         ~raw_response_to_string:Keeper_exact_flow_detail.raw_response_excerpt
         error);
    quarantine_candidate
      ~queue_ops
      prepared.entry
      candidate
      Exact_flow_execution_failed
;;
