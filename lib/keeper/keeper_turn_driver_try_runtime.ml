(** Typed retry projection helpers for the live named-runtime lane.

    Candidate iteration is owned by
    {!Keeper_turn_driver.attempt_runtime_candidates}. This module only maps
    structured AGENT_CORE errors into the provider-attempt facts that its retry
    predicate consumes. *)

let core_error_to_http_error error =
  match Keeper_runtime_attempt.core_error_to_runtime_outcome error with
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

let attempt_rejected_should_try_next = function
  | Agent_core.Error.Api
      (Agent_core.Retry.InvalidRequest
         { reason = Agent_core.Retry.Attempt_rejected; _ }) -> true
  | Agent_core.Error.Api
      (Agent_core.Retry.InvalidRequest
         { reason =
             ( Agent_core.Retry.Json_parse_error
             | Agent_core.Retry.Request_body_too_large _
             | Agent_core.Retry.Request_body_refused_by_provider _
             | Agent_core.Retry.Unknown_invalid_request )
         ; _
         })
  | Agent_core.Error.Api
      ( Agent_core.Retry.RateLimited _ | Agent_core.Retry.Overloaded _
      | Agent_core.Retry.ServerError _ | Agent_core.Retry.AuthError _
      | Agent_core.Retry.AuthorizationError _
      | Agent_core.Retry.PaymentRequired _ | Agent_core.Retry.NotFound _
      | Agent_core.Retry.ContextOverflow _ | Agent_core.Retry.InputCapacity _
      | Agent_core.Retry.NetworkError _ | Agent_core.Retry.Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _
  | Agent_core.Error.Internal_carried { message = _; _ } -> false
;;

(* Lives here rather than reusing [Keeper_error_classify.is_context_overflow]:
   that module depends on [Keeper_turn_driver], so the walk predicate cannot
   reach it without a module cycle. Api variants are enumerated so a new
   variant forces a compile-time walk decision instead of a silent [false]. *)
let context_overflow_should_try_next = function
  | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _) -> true
  | Agent_core.Error.Api
      ( Agent_core.Retry.RateLimited _ | Agent_core.Retry.Overloaded _
      | Agent_core.Retry.ServerError _ | Agent_core.Retry.AuthError _
      | Agent_core.Retry.AuthorizationError _
      | Agent_core.Retry.PaymentRequired _ | Agent_core.Retry.InvalidRequest _
      | Agent_core.Retry.NotFound _ | Agent_core.Retry.InputCapacity _
      | Agent_core.Retry.NetworkError _
      | Agent_core.Retry.Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> false
;;
