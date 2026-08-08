(** Provider-level error types.

    Independent of the OAS sdk_error hierarchy. Can be mapped to
    sdk_error at the boundary or used directly by consumers.

    @since 0.42.0 *)

type provider_error =
  | MissingApiKey of { var_name : string }
  | InvalidConfig of
      { field : string
      ; detail : string
      }
  | ParseError of { detail : string }
  | ProviderWireError of
      { provider : string
      ; format : Http_client.provider_wire_format
      ; kind : Http_client.provider_wire_error_kind
      ; detail : string
      }
  | ProviderReportedError of
      { provider : string
      ; error_type : string option
      ; detail : string
      }
  | UnknownVariant of
      { type_name : string
      ; value : string
      }
  | ProviderUnavailable of
      { provider : string
      ; detail : string
      }
  | RateLimit of
      { provider : string
      ; retry_after : float option
      ; detail : string
      }
  | HardQuota of
      { provider : string
      ; retry_after : float option
      ; detail : string
      }
  | CapacityExhausted of
      { scope : capacity_scope
      ; affected : string list
      ; retry_after : float option
      ; detail : string
      }
  | AuthError of
      { provider : string
      ; detail : string
      }
  | AuthorizationError of
      { provider : string
      ; detail : string
      }
  | ServerError of
      { provider : string
      ; code : int
      ; transient : bool
      ; detail : string
      }
  | NetworkError of
      { provider : string
      ; kind : Http_client.network_error_kind
      ; timeout_phase : Http_client.timeout_phase option
      ; detail : string
      }
  | Timeout of
      { provider : string
      ; timeout_phase : Http_client.timeout_phase option
      ; detail : string
      }
  | InvalidRequest of
      { provider : string
      ; reason : string
      }
  | NotFound of
      { provider : string
      ; detail : string
      }
  | ProviderTerminal of
      { provider : string
      ; reason : string
      ; detail : string
      }

and capacity_scope =
  | CapacityModel
  | CapacityAccount
  | CapacityRegion
  | CapacityProvider
  | CapacityUnknown

let provider_name = function
  | Some provider when String.trim provider <> "" -> provider
  | _ -> "unknown"
;;

let affected_provider provider = if provider = "unknown" then [] else [ provider ]

let capacity_scope_to_string = function
  | CapacityModel -> "model"
  | CapacityAccount -> "account"
  | CapacityRegion -> "region"
  | CapacityProvider -> "provider"
  | CapacityUnknown -> "unknown"
;;

let network_error_kind_to_string = function
  | Http_client.Connection_refused -> "connection_refused"
  | Http_client.Dns_failure -> "dns_failure"
  | Http_client.Tls_error -> "tls_error"
  | Http_client.Timeout -> "timeout"
  | Http_client.Local_resource_exhaustion -> "local_resource_exhaustion"
  | Http_client.End_of_file -> "end_of_file"
  | Http_client.Unknown -> "unknown"
;;

let timeout_phase_suffix = function
  | None -> ""
  | Some phase -> Printf.sprintf " phase=%s" (Http_client.timeout_phase_to_label phase)
;;

let retry_after_suffix = function
  | None -> ""
  | Some seconds -> Printf.sprintf " (retry_after: %.3fs)" seconds
;;

let affected_suffix = function
  | [] -> ""
  | affected -> Printf.sprintf " affected=[%s]" (String.concat "," affected)
;;

let to_string = function
  | MissingApiKey r -> Printf.sprintf "Missing API key env var: %s" r.var_name
  | InvalidConfig r -> Printf.sprintf "Invalid config '%s': %s" r.field r.detail
  | ParseError r -> Printf.sprintf "Parse error: %s" r.detail
  | ProviderWireError r ->
    Printf.sprintf
      "Provider '%s' wire error (%s/%s): %s"
      r.provider
      (Http_client.provider_wire_format_to_string r.format)
      (Http_client.provider_wire_error_kind_to_string r.kind)
      r.detail
  | ProviderReportedError r ->
    Printf.sprintf
      "Provider '%s' reported an error%s: %s"
      r.provider
      (match r.error_type with
       | Some error_type -> Printf.sprintf " (%s)" error_type
       | None -> "")
      r.detail
  | UnknownVariant r -> Printf.sprintf "Unknown %s variant: %s" r.type_name r.value
  | ProviderUnavailable r ->
    Printf.sprintf "Provider '%s' unavailable: %s" r.provider r.detail
  | RateLimit r ->
    Printf.sprintf
      "Provider '%s' rate limited: %s%s"
      r.provider
      r.detail
      (retry_after_suffix r.retry_after)
  | HardQuota r ->
    Printf.sprintf
      "Provider '%s' hard quota exhausted: %s%s"
      r.provider
      r.detail
      (retry_after_suffix r.retry_after)
  | CapacityExhausted r ->
    Printf.sprintf
      "Provider capacity exhausted (%s): %s%s%s"
      (capacity_scope_to_string r.scope)
      r.detail
      (affected_suffix r.affected)
      (retry_after_suffix r.retry_after)
  | AuthError r -> Printf.sprintf "Provider '%s' auth error: %s" r.provider r.detail
  | AuthorizationError r ->
    Printf.sprintf "Provider '%s' authorization error: %s" r.provider r.detail
  | ServerError r ->
    Printf.sprintf
      "Provider '%s' server error %d (transient=%b): %s"
      r.provider
      r.code
      r.transient
      r.detail
  | NetworkError r ->
    Printf.sprintf
      "Provider '%s' network error (%s%s): %s"
      r.provider
      (network_error_kind_to_string r.kind)
      (timeout_phase_suffix r.timeout_phase)
      r.detail
  | Timeout r ->
    Printf.sprintf
      "Provider '%s' timeout%s: %s"
      r.provider
      (timeout_phase_suffix r.timeout_phase)
      r.detail
  | InvalidRequest r ->
    Printf.sprintf "Provider '%s' invalid request: %s" r.provider r.reason
  | NotFound r -> Printf.sprintf "Provider '%s' not found: %s" r.provider r.detail
  | ProviderTerminal r ->
    Printf.sprintf "Provider '%s' terminal %s: %s" r.provider r.reason r.detail
;;

let of_retry_api_error ?provider err =
  let provider = provider_name provider in
  match err with
  | Retry.RateLimited r ->
    RateLimit { provider; retry_after = r.retry_after; detail = r.message }
  | Retry.Overloaded r ->
    CapacityExhausted
      { scope = CapacityProvider
      ; affected = affected_provider provider
      ; retry_after = None
      ; detail = r.message
      }
  | Retry.ServerError r ->
    ServerError
      { provider
      ; code = r.status
      ; transient = Retry.is_retryable err
      ; detail = r.message
      }
  | Retry.AuthError r -> AuthError { provider; detail = r.message }
  | Retry.AuthorizationError r -> AuthorizationError { provider; detail = r.message }
  | Retry.PaymentRequired r ->
    (* HTTP 402 is a typed payment boundary by status code alone. *)
    HardQuota { provider; retry_after = None; detail = r.message }
  | Retry.InvalidRequest r -> InvalidRequest { provider; reason = r.message }
  | Retry.NotFound r -> NotFound { provider; detail = r.message }
  | Retry.ContextOverflow r ->
    InvalidRequest { provider; reason = Retry.error_message (Retry.ContextOverflow r) }
  | Retry.InputCapacity r ->
    (* [Error.t] is the legacy provider-only surface and cannot preserve the
       constraint evidence. The Agent SDK [Error.Api] / error-domain path keeps
       [Retry.InputCapacity] typed end to end; new consumers must use it. *)
    InvalidRequest { provider; reason = Retry.error_message (Retry.InputCapacity r) }
  | Retry.NetworkError r ->
    NetworkError { provider; kind = r.kind; timeout_phase = None; detail = r.message }
  (* Preserve the transport phase carried by Retry.Timeout so a retried
     prefill timeout surfaces as [First_token] (not the default [None]
     that would collapse every retry-classified timeout into an
     unclassifiable provider timeout).  See http_client.timeout_phase. *)
  | Retry.Timeout r -> Timeout { provider; timeout_phase = r.phase; detail = r.message }
;;

let capacity_scope_of_http = function
  | Http_client.Failure_scope_model -> CapacityModel
  | Http_client.Failure_scope_account -> CapacityAccount
  | Http_client.Failure_scope_region -> CapacityRegion
  | Http_client.Failure_scope_provider -> CapacityProvider
  | Http_client.Failure_scope_unknown -> CapacityUnknown
;;

let of_provider_failure ?provider kind message =
  let provider = provider_name provider in
  match kind with
  | Http_client.Capacity_exhausted { scope; retry_after; model } ->
    let affected =
      match model with
      | Some model -> [ model ]
      | None -> affected_provider provider
    in
    CapacityExhausted
      { scope = capacity_scope_of_http scope; affected; retry_after; detail = message }
  | Http_client.Hard_quota { retry_after } ->
    HardQuota { provider; retry_after; detail = message }
  | Http_client.Capability_mismatch { capability } ->
    let reason =
      match capability with
      | Some capability -> Printf.sprintf "missing capability: %s" capability
      | None -> "missing provider capability"
    in
    InvalidRequest { provider; reason = reason ^ ": " ^ message }
  | Http_client.Cli_policy_invalid { tool_name; rule } ->
    let tool =
      match tool_name with
      | Some name -> name
      | None -> "unknown_tool"
    in
    let reason =
      match rule with
      | Some n -> Printf.sprintf "CLI policy rejected %s at rule %d" tool n
      | None -> Printf.sprintf "CLI policy rejected %s" tool
    in
    InvalidRequest { provider; reason = reason ^ ": " ^ message }
  | Http_client.Cli_startup_failed { reason } ->
    ProviderUnavailable
      { provider
      ; detail =
          Printf.sprintf
            "%s: %s"
            (Http_client.cli_startup_failure_reason_to_string reason)
            message
      }
  | Http_client.Provider_parse_error { parser } ->
    let parser =
      match parser with
      | Some parser -> parser
      | None -> "unknown_parser"
    in
    ParseError { detail = Printf.sprintf "%s: %s" parser message }
  | Http_client.Provider_wire_error { format; kind } ->
    ProviderWireError { provider; format; kind; detail = message }
  | Http_client.Provider_reported_error { error_type } ->
    ProviderReportedError { provider; error_type; detail = message }
  | Http_client.Request_body_too_large _ -> InvalidRequest { provider; reason = message }
  | Http_client.Response_body_too_large { limit_bytes } ->
    ParseError
      { detail =
          Printf.sprintf "provider response exceeded %d bytes: %s" limit_bytes message
      }
  | Http_client.Empty_completion { stop_reason } ->
    (match Retry.verdict_of_empty_completion ~stop_reason ~message with
     | Retry.Empty_overflow overflow ->
       (* Third promotion site of the #2621 misclassification fix: a
          ContextWindowExceeded empty completion is a caller-fixable context
          overflow, not provider unavailability. The overflow VALUE comes from
          the shared [Retry.verdict_of_empty_completion] classifier; this
          deliberate SDK boundary flattens it to a string via
          [Retry.error_message] into [InvalidRequest], preserving the typed →
          string boundary that keeps the public surface source-compatible. *)
       InvalidRequest { provider; reason = Retry.error_message overflow }
     | Retry.Empty_unattributed { token } ->
       (* An empty turn whose stop_reason token this SDK does not model is not
          evidence of provider unavailability, and rendering it as such invites
          the caller to retry the identical prompt — which never terminates when
          the real condition was an overflow reported with an unmodeled token.
          Flattened to the same [InvalidRequest] surface as the overflow case,
          naming the token so it can be modelled. *)
       InvalidRequest
         { provider
         ; reason =
             Printf.sprintf
               "empty completion with unmodeled stop_reason=%S: %s"
               token
               message
         }
     | Retry.Empty_attributed ->
       (* [stop_reason] stays typed until this deliberate SDK boundary.  The
          public error surface remains source-compatible: callers already handle
          a recognized non-overflow empty completion as provider unavailability,
          and no control flow reparses this diagnostic rendering. *)
       ProviderUnavailable
         { provider
         ; detail =
             Printf.sprintf
               "empty completion (stop_reason=%s): %s"
               (Types.stop_reason_to_string stop_reason)
               message
         })
  | Http_client.Context_overflow { limit } ->
    (* oas#2947: same SDK-boundary flattening as the Empty_overflow arm above —
       the typed overflow value is rendered via [Retry.error_message] into
       [InvalidRequest] so the public surface stays source-compatible, while
       the attribution path ([Provider_failure_attribution]) keeps the typed
       [Retry.ContextOverflow] for consumers that branch on it. *)
    InvalidRequest
      { provider
      ; reason = Retry.error_message (Retry.ContextOverflow { message; limit })
      }
  | Http_client.Unknown_provider_failure { reason } ->
    let reason =
      match reason with
      | Some reason -> reason
      | None -> "unknown_provider_failure"
    in
    ProviderUnavailable { provider; detail = Printf.sprintf "%s: %s" reason message }
;;

let of_http_error ?provider = function
  | Http_client.HttpError { code; body; retry_after_header } ->
    Retry.classify_error ~retry_after_header ~status:code ~body
    |> of_retry_api_error ?provider
  | Http_client.NetworkError { message; kind } ->
    NetworkError
      { provider = provider_name provider; kind; timeout_phase = None; detail = message }
  | Http_client.TimeoutError { message; phase } ->
    Timeout
      { provider = provider_name provider; timeout_phase = Some phase; detail = message }
  | Http_client.AcceptRejected { reason } ->
    InvalidRequest
      { provider = provider_name provider; reason = "accept rejected: " ^ reason }
  | Http_client.ProviderTerminal { kind = Http_client.Session_conflict; message } ->
    ProviderTerminal
      { provider = provider_name provider; reason = "session_conflict"; detail = message }
  | Http_client.ProviderTerminal { kind = Http_client.Other reason; message } ->
    ProviderTerminal { provider = provider_name provider; reason; detail = message }
  | Http_client.ProviderFailure { kind; message } ->
    of_provider_failure ?provider kind message
;;

let is_retryable = function
  | RateLimit _ -> true
  | CapacityExhausted _ -> true
  | ServerError r -> r.transient
  | NetworkError { kind = Http_client.Tls_error; _ } -> false
  | NetworkError { kind = Http_client.Local_resource_exhaustion; _ } -> false
  | NetworkError _ -> true
  | Timeout _ -> true
  | MissingApiKey _
  | InvalidConfig _
  | ParseError _
  | ProviderWireError _
  | ProviderReportedError _
  | UnknownVariant _
  | ProviderUnavailable _
  | HardQuota _
  | AuthError _
  | AuthorizationError _
  | InvalidRequest _
  | NotFound _
  | ProviderTerminal _ -> false
;;
