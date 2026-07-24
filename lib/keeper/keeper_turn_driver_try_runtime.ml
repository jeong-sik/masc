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

(* Lives here rather than reusing [Keeper_error_classify.is_context_overflow]:
   that module depends on [Keeper_turn_driver], so the walk predicate cannot
   reach it without a module cycle. Api variants are enumerated so a new
   variant forces a compile-time walk decision instead of a silent [false]. *)
let context_overflow_should_try_next = function
  | Agent_sdk.Error.Api (Agent_sdk.Retry.ContextOverflow _) -> true
  | Agent_sdk.Error.Api
      ( Agent_sdk.Retry.RateLimited _ | Agent_sdk.Retry.Overloaded _
      | Agent_sdk.Retry.ServerError _ | Agent_sdk.Retry.AuthError _
      | Agent_sdk.Retry.AuthorizationError _
      | Agent_sdk.Retry.PaymentRequired _ | Agent_sdk.Retry.InvalidRequest _
      | Agent_sdk.Retry.NotFound _ | Agent_sdk.Retry.InputCapacity _
      | Agent_sdk.Retry.NetworkError _
      | Agent_sdk.Retry.Timeout _ )
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ -> false
;;
