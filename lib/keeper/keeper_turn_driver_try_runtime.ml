(** Typed retry projection helpers for the live named-runtime lane.

    Candidate iteration is owned by
    {!Keeper_turn_driver.attempt_runtime_candidates}. This module only maps
    structured OAS errors into the provider-attempt facts that its retry
    predicate consumes. *)

let sdk_error_to_http_error error =
  match Keeper_runtime_attempt.sdk_error_to_runtime_outcome error with
  | Some (Runtime_attempt_fsm.Call_err http_error) -> Some http_error
  | Some (Runtime_attempt_fsm.Accept_rejected { reason; _ }) ->
    Some (Llm_provider.Http_client.AcceptRejected { reason })
  | Some (Runtime_attempt_fsm.Call_ok _) | None -> None
;;

let accept_no_progress_should_try_next error =
  match Keeper_internal_error.classify_masc_internal_error error with
  | Some internal_error ->
    Keeper_internal_error.accept_rejection_has_no_progress_retry_hint
      internal_error
  | None -> false
;;
