(** Closed ownership and detailed error evidence for resolved provider calls. *)

module Http = Llm_provider.Http_client
module Retry = Llm_provider.Retry

type failure_ownership =
  | Attempt_local
  | Session_local
  | Credential_pool
  | Runtime_binding
  | Endpoint
  | Provider_region
  | Provider
  | Unclassified

type evidence =
  | Http_status of int
  | Network of Http.network_error_kind
  | Timeout of Http.timeout_phase
  | Accept_rejected
  | Provider_terminal of Http.provider_terminal_kind
  | Provider_failure of Http.provider_failure_kind
  | Provider_configuration
  | Request_validation
  | Response_parse
  | Coarse_api_error
  | Coarse_provider_error

type t =
  { ownership : failure_ownership
  ; binding : Binding_identity.t option
  ; evidence : evidence
  }

type detailed_error =
  { error : Error.sdk_error
  ; provider_failure : t option
  }

type accept_rejected =
  | Api_invalid_request
  | Config_invalid_config of { field : string }

let invalid_request reason =
  Error.Api
    (Retry.InvalidRequest { message = reason; reason = Retry.Unknown_invalid_request })
;;

let sdk_error_of_http_error ?(accept_rejected = Api_invalid_request) err =
  match err with
  | Http.HttpError { code; body; retry_after_header } ->
    Error.Api (Retry.classify_error ~retry_after_header ~status:code ~body)
  | Http.NetworkError { message; kind } ->
    Error.Api (Retry.NetworkError { message; kind })
  | Http.TimeoutError _ -> Error.Provider (Llm_provider.Error.of_http_error err)
  | Http.AcceptRejected { reason } ->
    (match accept_rejected with
     | Api_invalid_request -> invalid_request reason
     | Config_invalid_config { field } ->
       Error.Config (Error.InvalidConfig { field; detail = reason }))
  | Http.ProviderFailure
      { kind = Http.Request_body_too_large { actual_bytes; limit_bytes }; message } ->
    Error.Api
      (Retry.InvalidRequest
         { message; reason = Retry.Request_body_too_large { actual_bytes; limit_bytes } })
  | Http.ProviderFailure { kind = Http.Context_overflow { limit }; message } ->
    (* oas#2947: a provider-reported context overflow (e.g. glm 1261) is the
       same consumer contract as a ContextWindowExceeded empty turn — only the
       consumer's context recovery (compaction/shrink) can make progress, so
       it must surface as the typed [Api ContextOverflow] and never as a
       generic invalid-request. *)
    Error.Api (Retry.ContextOverflow { message; limit })
  | Http.ProviderFailure { kind = Http.Empty_completion { stop_reason }; message } ->
    (* The #2621 empty-completion overflow rule is centralised in
       [Retry.verdict_of_empty_completion]. A ContextWindowExceeded empty turn
       surfaces as [Api ContextOverflow] so downstream overflow classifiers fire
       on the streaming path exactly as for HTTP-classified overflows; a
       recognized non-overflow stop_reason falls through to the same
       provider-unavailability handling as [ProviderTerminal] / other
       [ProviderFailure]. This site's [Error.Api] wrapper is preserved.

       An empty turn whose stop_reason token this SDK does not model is neither
       case. Routing it to provider-unavailability makes the consumer retry or
       rotate the identical prompt, which never terminates when the real
       condition was an overflow reported with an unmodeled token: the consumer
       reaches its compaction path only on a typed overflow, so the turn fails
       repeatedly without an error that names the cause. It is surfaced as a
       non-retryable request error naming the token instead.

       WORKAROUND: [InvalidRequest] is reused because [api_error] has no
       "unmodeled provider contract" variant, and adding one breaks every
       exhaustive matcher in this SDK and in its consumers. Root fix: a
       dedicated variant, scheduled with the next breaking API change. *)
    (match Retry.verdict_of_empty_completion ~stop_reason ~message with
     | Retry.Empty_overflow overflow -> Error.Api overflow
     | Retry.Empty_attributed -> Error.Provider (Llm_provider.Error.of_http_error err)
     | Retry.Empty_unattributed { token } ->
       Error.Api
         (Retry.InvalidRequest
            { message =
                Printf.sprintf
                  "empty completion with unmodeled stop_reason=%S: %s"
                  token
                  message
            ; reason = Retry.Unknown_invalid_request
            }))
  | Http.ProviderTerminal _ | Http.ProviderFailure _ ->
    Error.Provider (Llm_provider.Error.of_http_error err)
;;

let of_sdk_error error =
  let provider_failure =
    match error with
    | Error.Api _ ->
      Some { ownership = Unclassified; binding = None; evidence = Coarse_api_error }
    | Error.Provider _ ->
      Some { ownership = Unclassified; binding = None; evidence = Coarse_provider_error }
    | Error.Agent _
    | Error.Mcp _
    | Error.Config _
    | Error.Serialization _
    | Error.Io _
    | Error.Orchestration _
    | Error.Internal _ -> None
  in
  { error; provider_failure }
;;

let of_provider_configuration_error error =
  { error
  ; provider_failure =
      Some { ownership = Unclassified; binding = None; evidence = Provider_configuration }
  }
;;

let of_runtime_binding_error ~binding error =
  { error
  ; provider_failure =
      Some
        { ownership = Runtime_binding
        ; binding = Some binding
        ; evidence = Provider_configuration
        }
  }
;;

let of_attempt_error ~binding ~evidence error =
  { error
  ; provider_failure =
      Some { ownership = Attempt_local; binding = Some binding; evidence }
  }
;;

let of_request_validation_error ~binding error =
  of_attempt_error ~binding ~evidence:Request_validation error
;;

let of_response_parse_error ~binding error =
  of_attempt_error ~binding ~evidence:Response_parse error
;;

let credential_owned binding =
  if Binding_identity.has_credential_identity binding
  then Credential_pool
  else Unclassified
;;

let ownership_of_http_status ~binding code =
  match code with
  | 400 | 413 | 422 -> Attempt_local
  | 401 | 402 -> credential_owned binding
  | 404 -> Runtime_binding
  (* A generic server status does not identify whether the fault belongs to
     this binding, endpoint, region, or provider.  Only richer typed provider
     evidence may widen it beyond [Unclassified]. *)
  | _ -> Unclassified
;;

let ownership_of_network = function
  | Http.Connection_refused | Http.Dns_failure | Http.Tls_error | Http.End_of_file ->
    Endpoint
  | Http.Local_resource_exhaustion -> Attempt_local
  | Http.Timeout | Http.Unknown -> Unclassified
;;

let ownership_of_timeout = function
  | Http.Admission | Http.Queue | Http.Capacity_backpressure -> Attempt_local
  | Http.First_token
  | Http.Wall_clock
  | Http.Http_operation
  | Http.Non_streaming_body
  | Http.Stream_body
  | Http.Stream_idle _
  | Http.Provider_step
  | Http.Cli_stdout_idle
  | Http.Unknown_timeout -> Unclassified
;;

let ownership_of_capacity ~binding = function
  | Http.Failure_scope_model -> Runtime_binding
  | Http.Failure_scope_account -> credential_owned binding
  | Http.Failure_scope_region -> Provider_region
  | Http.Failure_scope_provider -> Provider
  | Http.Failure_scope_unknown -> Unclassified
;;

let ownership_of_cli_startup ~binding = function
  | Http.Executable_unavailable | Http.Configuration_invalid -> Runtime_binding
  | Http.Authentication_unavailable -> credential_owned binding
  | Http.Session_conflict_at_startup -> Session_local
  | Http.Unknown_cli_startup_failure -> Unclassified
;;

let ownership_of_provider_failure ~binding = function
  | Http.Capacity_exhausted { scope; _ } -> ownership_of_capacity ~binding scope
  | Http.Hard_quota _ -> credential_owned binding
  | Http.Capability_mismatch _
  | Http.Cli_policy_invalid _
  | Http.Provider_parse_error _
  | Http.Provider_wire_error _
  | Http.Request_body_too_large _
  | Http.Response_body_too_large _
  | Http.Empty_completion _
  | Http.Context_overflow _ -> Attempt_local
  | Http.Cli_startup_failed { reason } -> ownership_of_cli_startup ~binding reason
  | Http.Provider_reported_error _ | Http.Unknown_provider_failure _ -> Unclassified
;;

let attribution_of_http_error ~binding = function
  | Http.HttpError { code = 429; body; retry_after_header } ->
    (* HTTP 429 alone carries no provider-specific evidence of which lane
       is exhausted (model/account/region/provider) — that finer signal
       only exists in [Http.Capacity_exhausted] from transports that parse
       it out of provider-specific payloads. A raw 429 is honestly
       [Failure_scope_unknown] rather than a guess, but it is still routed
       through the typed capacity vocabulary (not the generic [Http_status]
       catch-all) so the retry_after evidence survives into attribution
       instead of being visible only in the classified [Retry.api_error]. *)
    let retry_after = Retry.resolve_retry_after ~body ~header:retry_after_header in
    let kind =
      Http.Capacity_exhausted
        { scope = Http.Failure_scope_unknown; retry_after; model = None }
    in
    { ownership = ownership_of_provider_failure ~binding kind
    ; binding = Some binding
    ; evidence = Provider_failure kind
    }
  | Http.HttpError { code; _ } ->
    { ownership = ownership_of_http_status ~binding code
    ; binding = Some binding
    ; evidence = Http_status code
    }
  | Http.NetworkError { kind; _ } ->
    { ownership = ownership_of_network kind
    ; binding = Some binding
    ; evidence = Network kind
    }
  | Http.TimeoutError { phase; _ } ->
    { ownership = ownership_of_timeout phase
    ; binding = Some binding
    ; evidence = Timeout phase
    }
  | Http.AcceptRejected _ ->
    { ownership = Attempt_local; binding = Some binding; evidence = Accept_rejected }
  | Http.ProviderTerminal { kind; _ } ->
    { ownership = Session_local
    ; binding = Some binding
    ; evidence = Provider_terminal kind
    }
  | Http.ProviderFailure { kind; _ } ->
    { ownership = ownership_of_provider_failure ~binding kind
    ; binding = Some binding
    ; evidence = Provider_failure kind
    }
;;

let of_http_error ?(accept_rejected = Api_invalid_request) ~binding http_error =
  { error = sdk_error_of_http_error ~accept_rejected http_error
  ; provider_failure = Some (attribution_of_http_error ~binding http_error)
  }
;;

let failure_ownership_to_string = function
  | Attempt_local -> "attempt_local"
  | Session_local -> "session_local"
  | Credential_pool -> "credential_pool"
  | Runtime_binding -> "runtime_binding"
  | Endpoint -> "endpoint"
  | Provider_region -> "provider_region"
  | Provider -> "provider"
  | Unclassified -> "unclassified"
;;

let network_to_string = function
  | Http.Connection_refused -> "connection_refused"
  | Http.Dns_failure -> "dns_failure"
  | Http.Tls_error -> "tls_error"
  | Http.Timeout -> "timeout"
  | Http.Local_resource_exhaustion -> "local_resource_exhaustion"
  | Http.End_of_file -> "end_of_file"
  | Http.Unknown -> "unknown"
;;

let provider_terminal_to_yojson = function
  | Http.Session_conflict -> `Assoc [ "kind", `String "session_conflict" ]
  | Http.Other _ -> `Assoc [ "kind", `String "other" ]
;;

let provider_failure_to_yojson = function
  | Http.Capacity_exhausted { scope; retry_after; model } ->
    let scope =
      match scope with
      | Http.Failure_scope_model -> "model"
      | Http.Failure_scope_account -> "account"
      | Http.Failure_scope_region -> "region"
      | Http.Failure_scope_provider -> "provider"
      | Http.Failure_scope_unknown -> "unknown"
    in
    `Assoc
      [ "kind", `String "capacity_exhausted"
      ; "scope", `String scope
      ; ( "retry_after"
        , match retry_after with
          | Some seconds -> `Float seconds
          | None -> `Null )
      ; "model_known", `Bool (Option.is_some model)
      ]
  | Http.Hard_quota { retry_after } ->
    `Assoc
      [ "kind", `String "hard_quota"
      ; ( "retry_after"
        , match retry_after with
          | Some seconds -> `Float seconds
          | None -> `Null )
      ]
  | Http.Capability_mismatch { capability } ->
    `Assoc
      [ "kind", `String "capability_mismatch"
      ; "capability_known", `Bool (Option.is_some capability)
      ]
  | Http.Cli_policy_invalid { tool_name; rule } ->
    `Assoc
      [ "kind", `String "cli_policy_invalid"
      ; "tool_known", `Bool (Option.is_some tool_name)
      ; ( "rule"
        , match rule with
          | Some rule -> `Int rule
          | None -> `Null )
      ]
  | Http.Cli_startup_failed { reason } ->
    `Assoc
      [ "kind", `String "cli_startup_failed"
      ; "reason", `String (Http.cli_startup_failure_reason_to_string reason)
      ]
  | Http.Provider_parse_error { parser } ->
    `Assoc
      [ "kind", `String "provider_parse_error"
      ; "parser_known", `Bool (Option.is_some parser)
      ]
  | Http.Provider_wire_error { format; kind } ->
    `Assoc
      [ "kind", `String "provider_wire_error"
      ; "format", `String (Http.provider_wire_format_to_string format)
      ; "wire_kind", `String (Http.provider_wire_error_kind_to_string kind)
      ]
  | Http.Provider_reported_error { error_type } ->
    `Assoc
      [ "kind", `String "provider_reported_error"
      ; "error_type_known", `Bool (Option.is_some error_type)
      ]
  | Http.Request_body_too_large { actual_bytes; limit_bytes } ->
    `Assoc
      [ "kind", `String "request_body_too_large"
      ; "actual_bytes", `Int actual_bytes
      ; "limit_bytes", `Int limit_bytes
      ]
  | Http.Response_body_too_large { limit_bytes } ->
    `Assoc [ "kind", `String "response_body_too_large"; "limit_bytes", `Int limit_bytes ]
  | Http.Empty_completion { stop_reason } ->
    `Assoc
      [ "kind", `String "empty_completion"
      ; ( "stop_reason"
        , `String (Llm_provider.Types.stop_reason_to_metric_label stop_reason) )
      ]
  | Http.Context_overflow { limit } ->
    `Assoc
      ([ "kind", `String "context_overflow" ]
       @
       match limit with
       | Some limit -> [ "limit", `Int limit ]
       | None -> [])
  | Http.Unknown_provider_failure _ ->
    `Assoc [ "kind", `String "unknown_provider_failure" ]
;;

let evidence_to_yojson = function
  | Http_status status -> `Assoc [ "kind", `String "http_status"; "status", `Int status ]
  | Network kind ->
    `Assoc [ "kind", `String "network"; "network_kind", `String (network_to_string kind) ]
  | Timeout phase ->
    `Assoc
      [ "kind", `String "timeout"; "phase", `String (Http.timeout_phase_to_label phase) ]
  | Accept_rejected -> `Assoc [ "kind", `String "accept_rejected" ]
  | Provider_terminal terminal -> provider_terminal_to_yojson terminal
  | Provider_failure failure -> provider_failure_to_yojson failure
  | Provider_configuration -> `Assoc [ "kind", `String "provider_configuration" ]
  | Request_validation -> `Assoc [ "kind", `String "request_validation" ]
  | Response_parse -> `Assoc [ "kind", `String "response_parse" ]
  | Coarse_api_error -> `Assoc [ "kind", `String "coarse_api_error" ]
  | Coarse_provider_error -> `Assoc [ "kind", `String "coarse_provider_error" ]
;;

let to_yojson attribution =
  `Assoc
    [ "ownership", `String (failure_ownership_to_string attribution.ownership)
    ; ( "binding"
      , match attribution.binding with
        | Some binding -> Binding_identity.to_redacted_yojson binding
        | None -> `Null )
    ; "evidence", evidence_to_yojson attribution.evidence
    ]
;;
