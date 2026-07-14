(** SDK error mapping for keeper-managed provider attempts. *)

let capacity_backpressure_source_to_failure_scope = function
  | Keeper_internal_error.Provider_capacity ->
    Llm_provider.Http_client.Failure_scope_provider
  | Keeper_internal_error.Client_capacity ->
    Llm_provider.Http_client.Failure_scope_account
  | Keeper_internal_error.Runtime_slot ->
    Llm_provider.Http_client.Failure_scope_unknown

let provider_error_to_http_error = function
  | Llm_provider.Error.RateLimit { retry_after; detail; _ }
  | Llm_provider.Error.HardQuota { retry_after; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = Failure_scope_provider; retry_after; model = None }
      ; message = detail
      }
  | Llm_provider.Error.CapacityExhausted { retry_after; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = Failure_scope_provider; retry_after; model = None }
      ; message = detail
      }
  | Llm_provider.Error.AuthError { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 401; body = detail }
  | Llm_provider.Error.AuthorizationError { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 403; body = detail }
  | Llm_provider.Error.ServerError { code; detail; _ } ->
    Llm_provider.Http_client.HttpError { code; body = detail }
  | Llm_provider.Error.InvalidRequest { reason; _ } ->
    Llm_provider.Http_client.HttpError { code = 400; body = reason }
  | Llm_provider.Error.ProviderTerminal { reason; detail; _ } ->
    let body = if String.trim detail = "" then reason else detail in
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capability_mismatch
            { capability = Some "permission" }
      ; message = body
      }
  | Llm_provider.Error.NotFound { detail; _ } ->
    Llm_provider.Http_client.HttpError
      { code = 404; body = if String.trim detail = "" then "model not found" else detail }
  | Llm_provider.Error.Timeout { detail; timeout_phase; _ } ->
    Llm_provider.Http_client.TimeoutError
      { message = detail
      ; phase =
          Option.value
            timeout_phase
            ~default:Llm_provider.Http_client.Unknown_timeout
      }
  | Llm_provider.Error.NetworkError { detail; kind; _ } ->
    Llm_provider.Http_client.NetworkError { message = detail; kind }
  | Llm_provider.Error.ParseError { detail } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "protocol_error"
      ; message = detail
      }
  | Llm_provider.Error.MissingApiKey { var_name } ->
    Llm_provider.Http_client.HttpError
      { code = 401; body = Printf.sprintf "missing API key: %s" var_name }
  | Llm_provider.Error.InvalidConfig { field; detail } ->
    Llm_provider.Http_client.HttpError
      { code = 400; body = Printf.sprintf "%s: %s" field detail }
  | Llm_provider.Error.UnknownVariant { type_name; value } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "unknown_variant"
      ; message = Printf.sprintf "%s: %s" type_name value
      }
  | Llm_provider.Error.ProviderUnavailable { detail; _ } ->
    Llm_provider.Http_client.NetworkError
      { message = detail; kind = Llm_provider.Http_client.Unknown }

let sdk_error_to_runtime_outcome err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Resumable_cli_session { detail; _ }) ->
    Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.NetworkError
            { message = detail; kind = Llm_provider.Http_client.Unknown }))
  | Some
      (Keeper_internal_error.Capacity_backpressure { detail; retry_after; source; _ }) ->
    let retry_after =
      match retry_after with
      | Keeper_internal_error.Explicit s -> Some s
      | No_retry_hint -> None
    in
    Some
      (Runtime_attempt_fsm.Call_err
         (Llm_provider.Http_client.ProviderFailure
            { kind =
                Llm_provider.Http_client.Capacity_exhausted
                  { scope = capacity_backpressure_source_to_failure_scope source
                  ; retry_after
                  ; model = None
                  }
            ; message = detail
            }))
  | Some _
  | None ->
    (match err with
     | Agent_sdk.Error.Api api_err ->
       let http_err =
         match api_err with
         | Llm_provider.Retry.InvalidRequest { message; _ } ->
           Llm_provider.Http_client.HttpError { code = 400; body = message }
         | ContextOverflow { message; _ } ->
           Llm_provider.Http_client.HttpError { code = 400; body = message }
         | RateLimited { message; _ } ->
           Llm_provider.Http_client.HttpError { code = 429; body = message }
         | PaymentRequired { message } ->
           Llm_provider.Http_client.HttpError { code = 402; body = message }
         | NotFound { message } ->
           Llm_provider.Http_client.HttpError { code = 404; body = message }
         | ServerError { status; message } ->
           Llm_provider.Http_client.HttpError { code = status; body = message }
         | AuthError { message } ->
           Llm_provider.Http_client.HttpError { code = 401; body = message }
         | AuthorizationError { message } ->
           Llm_provider.Http_client.HttpError { code = 403; body = message }
         | Overloaded { message } ->
           Llm_provider.Http_client.HttpError { code = 529; body = message }
         | NetworkError { message; kind } ->
           Llm_provider.Http_client.NetworkError { message; kind }
         | Timeout { message } ->
           Llm_provider.Http_client.NetworkError
             { message; kind = Llm_provider.Http_client.Timeout }
       in
       Some (Runtime_attempt_fsm.Call_err http_err)
     | Agent_sdk.Error.Provider provider_err ->
       Some (Runtime_attempt_fsm.Call_err (provider_error_to_http_error provider_err))
     | Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason { reason }) ->
       Some
         (Runtime_attempt_fsm.Call_err
            (Llm_provider.Http_client.AcceptRejected { reason }))
    | Agent_sdk.Error.Config
        (Agent_sdk.Error.InvalidConfig { field = "runtime_mcp_auth"; detail }) ->
       Some
         (Runtime_attempt_fsm.Call_err
            (Llm_provider.Http_client.AcceptRejected { reason = detail }))
     | Agent_sdk.Error.Agent _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.Internal _ -> None)

let sdk_error_is_hard_quota =
  Keeper_turn_driver_provider_attempt.sdk_error_is_hard_quota

let sdk_error_soft_rate_limited =
  Keeper_turn_driver_provider_attempt.sdk_error_soft_rate_limited

let sdk_error_is_resumable_cli_session err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Resumable_cli_session _) -> true
  | _ -> false
