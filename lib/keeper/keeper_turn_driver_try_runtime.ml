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

(* [api_error_of_error] projects the structured [Agent_core.Error.t] down to
   the [Retry.api_error] the candidate-fault judgment reads. Only the [Api]
   variant carries a [Retry.api_error]; every other variant is a transport,
   agent, MCP, config, serialization, IO, orchestration, or internal fact that
   the candidate-fault judgment does not classify, so it stays out of this
   predicate. *)
let api_error_of_error = function
  | Agent_core.Error.Api api -> Some api
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _
  | Agent_core.Error.Internal_carried _ -> None
;;

(* Access is a property of this candidate's provider/model binding. A different
   declared candidate can serve the request. This is not a retry of the same
   credential: the driver still requires its caller and effect-disposition
   authorities before advancing to the next candidate. A 402 is the same
   kind of fact about the binding's account (RFC-0440 §3): it cannot pay, so
   the walk moves on; [Error_domain.is_retryable] still refuses a retry of the
   same candidate, and the quota window records the exhaustion. A 404 is the
   same kind of fact about the binding's model: this candidate cannot serve a
   model it does not have, so the walk moves on to one that can.
   [Keeper_runtime_failure_route] already routes [NotFound] to
   [Model_unavailable]; the walk predicate must agree, or the lane stops on a
   candidate whose model does not exist instead of trying the next one.

   The predicate now reads the one closed [Candidate_fault] judgment
   (RFC-one-slot-fault-judgment-for-every-walk.md, #38472) instead of
   enumerating constructors: a refusal that is this binding's affair —
   credential (401/403), account (402), model (404), or admission
   ([InputCapacity], a pre-dispatch refusal of the prepared request that
   another binding may accept) — rotates the walk to the next candidate. The
   two walks (exact and Keeper) therefore agree that [InputCapacity] is a
   binding fact, closing the split where the exact walk advanced on it while
   the Keeper walk stopped. Official clients carry the same access facts as
   [Provider] errors. *)
let candidate_access_should_try_next error =
  match api_error_of_error error with
  | Some api ->
    (match Llm_provider.Candidate_fault.of_api_error api with
     | Llm_provider.Candidate_fault.Binding
         ( Credential
         | Account
         | Model_absent
         | Admission ) -> true
     | Llm_provider.Candidate_fault.Binding
         ( Rate_limit
         | Capacity
         | Server
         | Window
         | Body_limit
         | Deadline
         | Output_dialect
         | Refusal_unread )
     | Llm_provider.Candidate_fault.Unattributed
     | Llm_provider.Candidate_fault.Unknown_after_dispatch -> false)
  | None ->
    (match error with
     | Agent_core.Error.Provider
         ( Llm_provider.Error.AuthError _
         | Llm_provider.Error.AuthorizationError _
         | Llm_provider.Error.NotFound _ ) -> true
     | Agent_core.Error.Provider _
     | Agent_core.Error.Agent _
     | Agent_core.Error.Mcp _
     | Agent_core.Error.Config _
     | Agent_core.Error.Serialization _
     | Agent_core.Error.Io _
     | Agent_core.Error.Orchestration _
     | Agent_core.Error.Internal _
     | Agent_core.Error.Internal_carried _
     | Agent_core.Error.Api _ -> false)
;;

(* A candidate can reject this request without a machine-readable reason, or
   refuse the prepared request before dispatch. The predicate reads the one
   closed [Candidate_fault] judgment (RFC #38472) so the two walks agree:
   [Attempt_rejected] and [Json_parse_error] are both this binding's
   [Admission] (RFC §3.2 absorbs [Json_parse_error] into [Admission], a
   pre-dispatch refusal another binding may accept); [Refusal_body_not_received]
   is the unread refusal ([Binding Refusal_unread]); [Request_body_refused_by_provider]
   is this binding's body limit ([Binding Body_limit]); and
   [Unknown_invalid_request] is the un-attributed refusal ([Unattributed]), kept
   unknown rather than inferred from provider prose. Another declared candidate
   may accept the same semantic input once candidate-local recovery ends. The
   driver's caller and effect-disposition checks still authorize rotation. *)
let attempt_rejected_should_try_next error =
  match api_error_of_error error with
  | Some api ->
    (match Llm_provider.Candidate_fault.of_api_error api with
     | Llm_provider.Candidate_fault.Binding
         ( Admission
         | Refusal_unread )
     | Llm_provider.Candidate_fault.Unattributed -> true
     | Llm_provider.Candidate_fault.Binding
         ( Credential
         | Account
         | Model_absent
         | Rate_limit
         | Capacity
         | Server
         | Window
         | Deadline
         | Output_dialect
         | Body_limit (* INTENDED RED probe, task-1753: never merge *) )
     | Llm_provider.Candidate_fault.Unknown_after_dispatch -> false)
  | None -> false
;;

(* Lives here rather than reusing [Keeper_error_classify.is_context_overflow]:
   that module depends on [Keeper_turn_driver], so the walk predicate cannot
   reach it without a module cycle. The predicate reads the one closed
   [Candidate_fault] judgment: a typed [ContextOverflow] is a per-candidate
   window fact ([Binding Window]), so a later candidate with a larger window
   can serve the same turn. A new [Retry.api_error] constructor stops
   [Candidate_fault.of_api_error] from compiling, which forces a walk decision
   here instead of a silent [false]. *)
let context_overflow_should_try_next error =
  match api_error_of_error error with
  | Some api ->
    (match Llm_provider.Candidate_fault.of_api_error api with
     | Llm_provider.Candidate_fault.Binding Window -> true
     | Llm_provider.Candidate_fault.Binding
         ( Credential
         | Account
         | Model_absent
         | Rate_limit
         | Capacity
         | Server
         | Body_limit
         | Admission
         | Deadline
         | Output_dialect
         | Refusal_unread )
     | Llm_provider.Candidate_fault.Unattributed
     | Llm_provider.Candidate_fault.Unknown_after_dispatch -> false)
  | None -> false
;;
