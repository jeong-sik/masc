(** Cascade_attempt_fsm_capacity_backpressure — Capacity backpressure
    and soft rate-limit classification from SDK errors.

    Extracted from [cascade_attempt_fsm.ml] during godfile decomposition.
    Pure functions over [Agent_sdk.Error.sdk_error].

    @since God file decomposition *)

(* DET-OK: synthetic default backoff when provider omits Retry-After *)
let default_capacity_backpressure_backoff_sec =
  Cascade_health_tracker.default_capacity_backpressure_backoff_sec

let sdk_error_capacity_backpressure_retry_after_s (err : Agent_sdk.Error.sdk_error)
  : float option option =
  match err with
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.CapacityExhausted { retry_after; _ }) ->
    Some retry_after
  | _ -> None

type capacity_backpressure_retry_hint =
  | Cbr_explicit of float
  | Cbr_synthetic_default of float

let sdk_error_capacity_backpressure_source (err : Agent_sdk.Error.sdk_error)
  : Cascade_error_classify.capacity_backpressure_source option =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some (Cascade_error_classify.Capacity_backpressure { source; _ }) ->
    Some source
  | Some (Cascade_error_classify.Cascade_exhausted _)
  | Some (Cascade_error_classify.Resumable_cli_session _)
  | Some (Cascade_error_classify.No_tool_capable_provider _)
  | Some (Cascade_error_classify.Accept_rejected _)
  | Some (Cascade_error_classify.Admission_queue_timeout _)
  | Some (Cascade_error_classify.Admission_queue_rejected _)
  | Some (Cascade_error_classify.Turn_timeout _)
  | Some (Cascade_error_classify.Provider_timeout _)
  | Some (Cascade_error_classify.Max_tokens_ceiling_violation _)
  | Some (Cascade_error_classify.Ambiguous_post_commit _)
  | Some (Cascade_error_classify.Retry_admission_denied _)
  | Some (Cascade_error_classify.Internal_unhandled_exception _)
  | Some (Cascade_error_classify.Internal_bridge_exception _)
  | Some (Cascade_error_classify.Internal_contract_rejected _)
  | None -> None

let sdk_error_capacity_backpressure_retry_hint (err : Agent_sdk.Error.sdk_error)
  : capacity_backpressure_retry_hint option =
  match Cascade_error_classify.classify_masc_internal_error err with
  | Some (Cascade_error_classify.Capacity_backpressure { retry_after; _ }) ->
    (* Read provenance directly from the typed carrier: a [Synthetic_default]
       can no longer reach the [Cbr_explicit] branch. *)
    (match retry_after with
     | Cascade_internal_error.Explicit s when s > 0.0 -> Some (Cbr_explicit s)
     | Cascade_internal_error.Explicit _ ->
       (* defensive: a non-positive explicit value is treated as missing *)
       Some (Cbr_synthetic_default default_capacity_backpressure_backoff_sec)
     | Cascade_internal_error.Synthetic_default s -> Some (Cbr_synthetic_default s)
     | Cascade_internal_error.No_retry_hint ->
       Some (Cbr_synthetic_default default_capacity_backpressure_backoff_sec))
  | Some (Cascade_error_classify.Cascade_exhausted _)
  | Some (Cascade_error_classify.Resumable_cli_session _)
  | Some (Cascade_error_classify.No_tool_capable_provider _)
  | Some (Cascade_error_classify.Accept_rejected _)
  | Some (Cascade_error_classify.Admission_queue_timeout _)
  | Some (Cascade_error_classify.Admission_queue_rejected _)
  | Some (Cascade_error_classify.Turn_timeout _)
  | Some (Cascade_error_classify.Provider_timeout _)
  | Some (Cascade_error_classify.Max_tokens_ceiling_violation _)
  | Some (Cascade_error_classify.Ambiguous_post_commit _)
  | Some (Cascade_error_classify.Retry_admission_denied _)
  | Some (Cascade_error_classify.Internal_unhandled_exception _)
  | Some (Cascade_error_classify.Internal_bridge_exception _)
  | Some (Cascade_error_classify.Internal_contract_rejected _)
  | None -> None

let sdk_error_soft_rate_limited (err : Agent_sdk.Error.sdk_error)
  : float option option =
  match err with
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited { retry_after; _ } as api_err)
    when not (Llm_provider.Retry.is_hard_quota api_err) ->
    Some retry_after
  | Agent_sdk.Error.Provider (Llm_provider.Error.RateLimit { retry_after; _ }) ->
    Some retry_after
  (* Hard-quota RateLimited is handled separately and other Api / non-Api
     errors do not represent soft rate limiting. *)
  | Agent_sdk.Error.Api (Llm_provider.Retry.RateLimited _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Overloaded _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ServerError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.AuthError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.InvalidRequest _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NotFound _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.ContextOverflow _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.NetworkError _)
  | Agent_sdk.Error.Api (Llm_provider.Retry.Timeout _)
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> None
