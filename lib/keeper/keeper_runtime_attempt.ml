(** agent-core error mapping for keeper-managed provider attempts. *)

let capacity_backpressure_source_to_failure_scope = function
  | Keeper_internal_error.Provider_capacity ->
    Llm_provider.Http_client.Failure_scope_provider
  | Keeper_internal_error.Client_capacity ->
    Llm_provider.Http_client.Failure_scope_account
  | Keeper_internal_error.Runtime_slot ->
    Llm_provider.Http_client.Failure_scope_unknown

let http_error ~code ~body =
  Llm_provider.Http_client.HttpError { code; body; retry_after_header = None }

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
    http_error ~code:401 ~body:detail
  | Llm_provider.Error.AuthorizationError { detail; _ } ->
    http_error ~code:403 ~body:detail
  | Llm_provider.Error.ServerError { code; detail; _ } ->
    http_error ~code ~body:detail
  | Llm_provider.Error.InvalidRequest { reason; _ } ->
    http_error ~code:400 ~body:reason
  | Llm_provider.Error.ProviderTerminal { reason; detail; _ } ->
    let body = if String.trim detail = "" then reason else detail in
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capability_mismatch
            { capability = Some "permission" }
      ; message = body
      }
  | Llm_provider.Error.NotFound { detail; _ } ->
    http_error
      ~code:404
      ~body:(if String.trim detail = "" then "model not found" else detail)
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
  | Llm_provider.Error.ProviderWireError { format; kind; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Provider_wire_error { format; kind }
      ; message = detail
      }
  | Llm_provider.Error.ProviderReportedError { error_type; detail; _ } ->
    Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Provider_reported_error { error_type }
      ; message = detail
      }
  | Llm_provider.Error.ParseError { detail } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "protocol_error"
      ; message = detail
      }
  | Llm_provider.Error.MissingApiKey { var_name } ->
    http_error ~code:401 ~body:(Printf.sprintf "missing API key: %s" var_name)
  | Llm_provider.Error.InvalidConfig { field; detail } ->
    http_error ~code:400 ~body:(Printf.sprintf "%s: %s" field detail)
  | Llm_provider.Error.UnknownVariant { type_name; value } ->
    Llm_provider.Http_client.ProviderTerminal
      { kind = Llm_provider.Http_client.Other "unknown_variant"
      ; message = Printf.sprintf "%s: %s" type_name value
      }
  | Llm_provider.Error.ProviderUnavailable { detail; _ } ->
    Llm_provider.Http_client.NetworkError
      { message = detail; kind = Llm_provider.Http_client.Unknown }
  | Llm_provider.Error.EmptyCompletion { stop_reason; detail; _ } ->
    Llm_provider.Http_client.NetworkError
      { message =
          Printf.sprintf
            "empty completion (stop_reason=%s): %s"
            (Llm_provider.Types.stop_reason_to_string stop_reason)
            detail
      ; kind = Llm_provider.Http_client.Unknown
      }

let core_error_to_runtime_outcome err =
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
     | Agent_core.Error.Api api_err ->
       let http_err =
         match api_err with
         | Llm_provider.Retry.InvalidRequest { message; _ } ->
           http_error ~code:400 ~body:message
         | ContextOverflow { message; _ } ->
           http_error ~code:400 ~body:message
         | InputCapacity { message; _ } ->
           http_error ~code:400 ~body:message
         | RateLimited { message; retry_after } ->
           (* Reconstruction boundary: [retry_after] is the resolved value
              (body-or-header) and the header slot is the only retry-after
              carrier on [HttpError], so it re-enters here rather than being
              dropped. *)
           Llm_provider.Http_client.HttpError
             { code = 429; body = message; retry_after_header = retry_after }
         | PaymentRequired { message } ->
           http_error ~code:402 ~body:message
         | NotFound { message } ->
           http_error ~code:404 ~body:message
         | ServerError { status; message } ->
           http_error ~code:status ~body:message
         | AuthError { message } ->
           http_error ~code:401 ~body:message
         | AuthorizationError { message } ->
           http_error ~code:403 ~body:message
         | Overloaded { message } ->
           http_error ~code:529 ~body:message
         | NetworkError { message; kind } ->
           Llm_provider.Http_client.NetworkError { message; kind }
         | Timeout { message; phase } ->
           (* [Http_client.Timeout] is the ETIMEDOUT transport kind, but
              [Retry.Timeout] also covers Admission, Queue, First_token and
              Capacity_backpressure waits that never touched a socket.
              [TimeoutError] carries the phase, so route there and keep it. *)
           Llm_provider.Http_client.TimeoutError
             { message
             ; phase =
                 (* DET-OK: [Unknown_timeout] is agent core's own constructor for an
                    unattributed timeout — it names the absence, not a real phase. *)
                 Option.value phase ~default:Llm_provider.Http_client.Unknown_timeout
             }
       in
       Some (Runtime_attempt_fsm.Call_err http_err)
     | Agent_core.Error.Provider provider_err ->
       Some (Runtime_attempt_fsm.Call_err (provider_error_to_http_error provider_err))
     | Agent_core.Error.Agent (Agent_core.Error.UnrecognizedStopReason { reason }) ->
       Some
         (Runtime_attempt_fsm.Call_err
            (Llm_provider.Http_client.AcceptRejected { reason }))
    | Agent_core.Error.Agent _
     | Agent_core.Error.Config _
     | Agent_core.Error.Mcp _
     | Agent_core.Error.Serialization _
     | Agent_core.Error.Io _
     | Agent_core.Error.Orchestration _
     | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> None)
