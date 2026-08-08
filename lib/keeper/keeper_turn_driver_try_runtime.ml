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
  | Masc_agent_core.Error.Api (Masc_agent_core.Retry.ContextOverflow _) -> true
  | Masc_agent_core.Error.Api
      ( Masc_agent_core.Retry.RateLimited _ | Masc_agent_core.Retry.Overloaded _
      | Masc_agent_core.Retry.ServerError _ | Masc_agent_core.Retry.AuthError _
      | Masc_agent_core.Retry.AuthorizationError _
      | Masc_agent_core.Retry.PaymentRequired _ | Masc_agent_core.Retry.InvalidRequest _
      | Masc_agent_core.Retry.NotFound _ | Masc_agent_core.Retry.InputCapacity _
      | Masc_agent_core.Retry.NetworkError _
      | Masc_agent_core.Retry.Timeout _ )
  | Masc_agent_core.Error.Provider _
  | Masc_agent_core.Error.Agent _
  | Masc_agent_core.Error.Mcp _
  | Masc_agent_core.Error.Config _
  | Masc_agent_core.Error.Serialization _
  | Masc_agent_core.Error.Io _
  | Masc_agent_core.Error.Orchestration _
  | Masc_agent_core.Error.Internal _ -> false
;;
