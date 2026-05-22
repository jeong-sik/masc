(** Provider-error -> HTTP-error typed mappers for the cascade attempt
    FSM.

    [provider_capacity_scope_to_http] — closed 5-arm map from
    [Llm_provider.Error.capacity_scope] to
    [Llm_provider.Http_client.failure_scope].

    [provider_error_to_http_error] — closed 14-arm map from
    [Agent_sdk.Error.provider_error] to
    [Llm_provider.Http_client.http_error]. Each arm converts an OAS-
    surfaced provider error variant into the dashboard-rendered HTTP
    failure typed envelope (HttpError + status code, ProviderFailure
    + structured kind, AcceptRejected, ProviderTerminal,
    TimeoutError, NetworkError).

    Pure typed-to-typed conversion — no parent state, no I/O. All
    arms are exhaustive (compiler-enforced). Verbatim extract from
    [Cascade_attempt_fsm]; all callers are internal to the parent. *)

let provider_capacity_scope_to_http = function
  | Llm_provider.Error.CapacityModel -> Llm_provider.Http_client.Failure_scope_model
  | Llm_provider.Error.CapacityAccount ->
    Llm_provider.Http_client.Failure_scope_account
  | Llm_provider.Error.CapacityRegion ->
    Llm_provider.Http_client.Failure_scope_region
  | Llm_provider.Error.CapacityProvider ->
    Llm_provider.Http_client.Failure_scope_provider
  | Llm_provider.Error.CapacityUnknown ->
    Llm_provider.Http_client.Failure_scope_unknown

let provider_error_to_http_error (err : Agent_sdk.Error.provider_error)
  : Llm_provider.Http_client.http_error =
  let module E = Llm_provider.Error in
  let message = E.to_string err in
  match err with
  | E.MissingApiKey _ | E.InvalidConfig _ ->
    Llm_provider.Http_client.AcceptRejected { reason = message }
  | E.ParseError { detail } ->
    Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Provider_parse_error { parser = None }
      ; message = detail
      }
  | E.UnknownVariant { type_name; value } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Unknown_provider_failure
            { reason = Some (Printf.sprintf "%s:%s" type_name value) }
      ; message
      }
  | E.ProviderUnavailable { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 503; body = detail }
  | E.RateLimit { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 429; body = detail }
  | E.HardQuota { retry_after; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Hard_quota { retry_after }
      ; message = detail
      }
  | E.CapacityExhausted { scope; affected; retry_after; detail } ->
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = provider_capacity_scope_to_http scope
            ; retry_after
            ; model = List.find_opt (fun value -> String.trim value <> "") affected
            }
      ; message = detail
      }
  | E.AuthError { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 401; body = detail }
  | E.ServerError { code; detail; _ } ->
    Llm_provider.Http_client.HttpError { code; body = detail }
  | E.NetworkError { timeout_phase = Some phase; detail; _ } ->
    Llm_provider.Http_client.TimeoutError { message = detail; phase }
  | E.NetworkError { kind; timeout_phase = None; detail; _ } ->
    Llm_provider.Http_client.NetworkError { message = detail; kind }
  | E.Timeout { timeout_phase; detail; _ } ->
    let phase =
      match timeout_phase with
      | Some phase -> phase
      | None ->
        (* DET-OK: OAS provider omitted timeout_phase; Unknown_timeout is an
           explicit typed sentinel, not a permissive branch heuristic. *)
        Llm_provider.Http_client.Unknown_timeout
    in
    Llm_provider.Http_client.TimeoutError
      { message = detail; phase }
  | E.InvalidRequest { reason; _ } ->
    Llm_provider.Http_client.HttpError { code = 400; body = reason }
  | E.NotFound { detail; _ } ->
    Llm_provider.Http_client.HttpError { code = 404; body = detail }
  | E.ProviderTerminal { reason; detail; _ } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other reason; message = detail }
