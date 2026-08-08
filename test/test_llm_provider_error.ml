(** Coverage for [Llm_provider.Error.provider_error], its [to_string]
    formatter, and typed transport/retry mapping (oas#1175 - file at 0% coverage in the
    initial coverage measurement (`66.42%`, run `24887636744`)).

    The formatter has one case per variant; the [to_string] group keeps
    one assertion per [provider_error] variant while the mapping group
    covers the conversion boundaries. *)

open Alcotest
open Llm_provider

let test_missing_api_key () =
  check
    string
    "MissingApiKey format"
    "Missing API key env var: OPENAI_API_KEY"
    (Error.to_string (Error.MissingApiKey { var_name = "OPENAI_API_KEY" }))
;;

let test_invalid_config () =
  check
    string
    "InvalidConfig format"
    "Invalid config 'temperature': must be in [0, 2]"
    (Error.to_string
       (Error.InvalidConfig { field = "temperature"; detail = "must be in [0, 2]" }))
;;

let test_parse_error () =
  check
    string
    "ParseError format"
    "Parse error: unexpected token at line 3"
    (Error.to_string (Error.ParseError { detail = "unexpected token at line 3" }))
;;

let test_unknown_variant () =
  check
    string
    "UnknownVariant format"
    "Unknown stop_reason variant: max_tokens_exceeded"
    (Error.to_string
       (Error.UnknownVariant { type_name = "stop_reason"; value = "max_tokens_exceeded" }))
;;

let test_provider_unavailable () =
  check
    string
    "ProviderUnavailable format"
    "Provider 'anthropic' unavailable: HTTP 503 retry-after exhausted"
    (Error.to_string
       (Error.ProviderUnavailable
          { provider = "anthropic"; detail = "HTTP 503 retry-after exhausted" }))
;;

let test_rate_limit () =
  check
    string
    "RateLimit format"
    "Provider 'anthropic' rate limited: quota window exhausted (retry_after: 1.250s)"
    (Error.to_string
       (Error.RateLimit
          { provider = "anthropic"
          ; retry_after = Some 1.25
          ; detail = "quota window exhausted"
          }))
;;

let test_hard_quota () =
  check
    string
    "HardQuota format"
    "Provider 'zai' hard quota exhausted: no remaining balance"
    (Error.to_string
       (Error.HardQuota
          { provider = "zai"; retry_after = None; detail = "no remaining balance" }))
;;

let test_capacity_exhausted () =
  check
    string
    "CapacityExhausted format"
    "Provider capacity exhausted (model): model queue saturated affected=[gemini-3-pro] \
     (retry_after: 7.000s)"
    (Error.to_string
       (Error.CapacityExhausted
          { scope = Error.CapacityModel
          ; affected = [ "gemini-3-pro" ]
          ; retry_after = Some 7.0
          ; detail = "model queue saturated"
          }))
;;

let test_auth_error () =
  check
    string
    "AuthError format"
    "Provider 'openai' auth error: invalid API key"
    (Error.to_string
       (Error.AuthError { provider = "openai"; detail = "invalid API key" }))
;;

let test_authorization_error () =
  check
    string
    "AuthorizationError format"
    "Provider 'openai' authorization error: forbidden"
    (Error.to_string
       (Error.AuthorizationError { provider = "openai"; detail = "forbidden" }))
;;

let test_server_error () =
  check
    string
    "ServerError format"
    "Provider 'openai' server error 503 (transient=true): down"
    (Error.to_string
       (Error.ServerError
          { provider = "openai"; code = 503; transient = true; detail = "down" }))
;;

let test_network_error () =
  check
    string
    "NetworkError format"
    "Provider 'local' network error (dns_failure): lookup failed"
    (Error.to_string
       (Error.NetworkError
          { provider = "local"
          ; kind = Http_client.Dns_failure
          ; timeout_phase = None
          ; detail = "lookup failed"
          }))
;;

let test_timeout () =
  check
    string
    "Timeout format"
    "Provider 'gemini' timeout: request exceeded budget"
    (Error.to_string
       (Error.Timeout
          { provider = "gemini"
          ; timeout_phase = None
          ; detail = "request exceeded budget"
          }))
;;

let test_timeout_phase () =
  check
    string
    "Timeout phase format"
    "Provider 'openai' timeout phase=stream_idle:streaming_thinking: stalled"
    (Error.to_string
       (Error.Timeout
          { provider = "openai"
          ; timeout_phase = Some (Http_client.Stream_idle Http_client.Streaming_thinking)
          ; detail = "stalled"
          }))
;;

let test_invalid_request () =
  check
    string
    "InvalidRequest format"
    "Provider 'anthropic' invalid request: context too long"
    (Error.to_string
       (Error.InvalidRequest { provider = "anthropic"; reason = "context too long" }))
;;

let test_not_found () =
  check
    string
    "NotFound format"
    "Provider 'gemini' not found: model not available"
    (Error.to_string
       (Error.NotFound { provider = "gemini"; detail = "model not available" }))
;;

let test_provider_terminal () =
  check
    string
    "ProviderTerminal format"
    "Provider 'claude_code' terminal session_conflict: session lease lost"
    (Error.to_string
       (Error.ProviderTerminal
          { provider = "claude_code"
          ; reason = "session_conflict"
          ; detail = "session lease lost"
          }))
;;

let test_retry_rate_limit_mapping () =
  let err =
    Error.of_retry_api_error
      ~provider:"anthropic"
      (Retry.RateLimited { retry_after = Some 2.5; message = "try later" })
  in
  match err with
  | Error.RateLimit { provider; retry_after; detail } ->
    check string "provider" "anthropic" provider;
    check (option (float 0.001)) "retry_after" (Some 2.5) retry_after;
    check string "detail" "try later" detail
  | _ -> fail "expected RateLimit"
;;

let test_retry_rate_limit_prose_mapping () =
  let err =
    Error.of_retry_api_error
      ~provider:"zai"
      (Retry.RateLimited
         { retry_after = Some 10.0
         ; message = "Insufficient balance or no resource package. Please recharge."
         })
  in
  match err with
  | Error.RateLimit { provider; retry_after; detail } ->
    check string "provider" "zai" provider;
    check (option (float 0.001)) "retry_after" (Some 10.0) retry_after;
    check
      string
      "detail"
      "Insufficient balance or no resource package. Please recharge."
      detail
  | _ -> fail "expected RateLimit"
;;

let test_retry_payment_required_mapping () =
  (* HTTP 402 (e.g. DeepSeek's "Insufficient Balance") is a hard billing
     signal by status code alone — it maps onto the same [HardQuota]
     provider_error rather than [InvalidRequest]. *)
  let err =
    Error.of_retry_api_error
      ~provider:"deepseek"
      (Retry.PaymentRequired { message = "Insufficient Balance" })
  in
  match err with
  | Error.HardQuota { provider; retry_after; detail } ->
    check string "provider" "deepseek" provider;
    check (option (float 0.001)) "retry_after" None retry_after;
    check string "detail" "Insufficient Balance" detail
  | _ -> fail "expected HardQuota"
;;

let test_retry_overloaded_unknown_provider_mapping () =
  let check_unknown_provider provider =
    let err =
      Error.of_retry_api_error ?provider (Retry.Overloaded { message = "busy" })
    in
    match err with
    | Error.CapacityExhausted { scope; affected; retry_after; detail } ->
      check bool "scope" true (scope = Error.CapacityProvider);
      check (list string) "affected" [] affected;
      check (option (float 0.001)) "retry_after" None retry_after;
      check string "detail" "busy" detail
    | _ -> fail "expected CapacityExhausted"
  in
  check_unknown_provider None;
  check_unknown_provider (Some "")
;;

let test_http_capacity_failure_mapping () =
  let err =
    Error.of_http_error
      ~provider:"gemini"
      (Http_client.ProviderFailure
         { kind =
             Http_client.Capacity_exhausted
               { scope = Http_client.Failure_scope_model
               ; retry_after = Some 7.0
               ; model = Some "gemini-3-pro"
               }
         ; message = "model queue saturated"
         })
  in
  match err with
  | Error.CapacityExhausted { scope; affected; retry_after; detail } ->
    check bool "scope" true (scope = Error.CapacityModel);
    check (list string) "affected" [ "gemini-3-pro" ] affected;
    check (option (float 0.001)) "retry_after" (Some 7.0) retry_after;
    check string "detail" "model queue saturated" detail
  | _ -> fail "expected CapacityExhausted"
;;

let test_http_server_error_mapping () =
  let err =
    Error.of_http_error
      ~provider:"openai"
      (Http_client.HttpError { code = 503; body = "down"; retry_after_header = None })
  in
  match err with
  | Error.ServerError { provider; code; transient; detail } ->
    check string "provider" "openai" provider;
    check int "code" 503 code;
    check bool "transient" true transient;
    check string "detail" "down" detail
  | _ -> fail "expected ServerError"
;;

let test_http_terminal_mapping () =
  let err =
    Error.of_http_error
      ~provider:"claude_code"
      (Http_client.ProviderTerminal
         { kind = Http_client.Session_conflict; message = "session lease lost" })
  in
  match err with
  | Error.ProviderTerminal { provider; reason; detail } ->
    check string "provider" "claude_code" provider;
    check string "reason" "session_conflict" reason;
    check string "detail" "session lease lost" detail
  | _ -> fail "expected ProviderTerminal"
;;

let test_http_network_error_mapping () =
  let err =
    Error.of_http_error
      ~provider:"local"
      (Http_client.NetworkError { message = "read timed out"; kind = Http_client.Timeout })
  in
  match err with
  | Error.NetworkError { provider; kind; timeout_phase; detail } ->
    check string "provider" "local" provider;
    check bool "kind" true (kind = Http_client.Timeout);
    check
      (option string)
      "timeout phase"
      None
      (Option.map Http_client.timeout_phase_to_label timeout_phase);
    check string "detail" "read timed out" detail
  | _ -> fail "expected NetworkError"
;;

let test_http_timeout_error_mapping () =
  let err =
    Error.of_http_error
      ~provider:"openai"
      (Http_client.TimeoutError
         { message = "stream stalled"
         ; phase = Http_client.Stream_idle Http_client.Streaming_thinking
         })
  in
  match err with
  | Error.Timeout { provider; timeout_phase; detail } ->
    check string "provider" "openai" provider;
    check
      (option string)
      "phase"
      (Some "stream_idle:streaming_thinking")
      (Option.map Http_client.timeout_phase_to_label timeout_phase);
    check string "detail" "stream stalled" detail
  | _ -> fail "expected Timeout"
;;

let test_retry_timeout_phase_mapping () =
  (* Retry.Timeout carries the transport phase that Http_client.TimeoutError
     attached (complete_stream's local catch sets First_token for prefill).
     [of_retry_api_error] must preserve it onto Error.Timeout.timeout_phase:
     a prefill timeout that exhausts retries must still surface as
     [First_token], not collapse to [None] (which would re-introduce the
     phase mislabeling that PR #2093 fixed at the transport layer). *)
  let err =
    Error.of_retry_api_error
      ~provider:"ollama"
      (Retry.Timeout
         { message = "prefill exceeded first-token budget"
         ; phase = Some Http_client.First_token
         })
  in
  match err with
  | Error.Timeout { provider; timeout_phase; detail } ->
    check string "provider" "ollama" provider;
    check
      (option string)
      "phase"
      (Some "first_token")
      (Option.map Http_client.timeout_phase_to_label timeout_phase);
    check string "detail" "prefill exceeded first-token budget" detail
  | _ -> fail "expected Timeout"
;;

let test_retry_remaining_variants_mapping () =
  let cases =
    [ ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.AuthError { message = "bad key" })
      , "auth" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.AuthorizationError { message = "forbidden" })
      , "authorization" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.InvalidRequest
             { message = "bad payload"; reason = Unknown_invalid_request })
      , "invalid" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.NotFound { message = "missing model" })
      , "not_found" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.ContextOverflow { message = "too long"; limit = Some 123 })
      , "context" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.NetworkError { message = "tls"; kind = Http_client.Tls_error })
      , "network" )
    ; ( Error.of_retry_api_error
          ~provider:"openai"
          (Retry.Timeout { message = "slow"; phase = None })
      , "timeout" )
    ]
  in
  List.iter
    (fun (err, expected) ->
       match expected, err with
       | "auth", Error.AuthError { detail; _ } ->
         check string "auth detail" "bad key" detail
       | "authorization", Error.AuthorizationError { detail; _ } ->
         check string "authorization detail" "forbidden" detail
       | "invalid", Error.InvalidRequest { reason; _ } ->
         check string "invalid reason" "bad payload" reason
       | "not_found", Error.NotFound { detail; _ } ->
         check string "not found detail" "missing model" detail
       | "context", Error.InvalidRequest { reason; _ } ->
         check bool "context reason" true (String.length reason > 0)
       | "network", Error.NetworkError { kind = Http_client.Tls_error; detail; _ } ->
         check string "network detail" "tls" detail
       | "timeout", Error.Timeout { detail; _ } ->
         check string "timeout detail" "slow" detail
       | _ -> fail ("unexpected mapping for " ^ expected))
    cases
;;

let test_provider_failure_remaining_variants_mapping () =
  let provider_failure ?provider kind message =
    Error.of_http_error ?provider (Http_client.ProviderFailure { kind; message })
  in
  let hard_quota =
    provider_failure
      ~provider:"gemini"
      (Http_client.Hard_quota { retry_after = Some 4.0 })
      "billing"
  in
  (match hard_quota with
   | Error.HardQuota { provider; retry_after; detail } ->
     check string "hard quota provider" "gemini" provider;
     check (option (float 0.001)) "hard quota retry after" (Some 4.0) retry_after;
     check string "hard quota detail" "billing" detail
   | _ -> fail "expected HardQuota");
  let capacity_unknown_provider =
    provider_failure
      ~provider:""
      (Http_client.Capacity_exhausted
         { scope = Http_client.Failure_scope_account; retry_after = None; model = None })
      "account queue"
  in
  (match capacity_unknown_provider with
   | Error.CapacityExhausted { scope; affected; detail; _ } ->
     check bool "account scope" true (scope = Error.CapacityAccount);
     check (list string) "unknown provider has no affected list" [] affected;
     check string "capacity detail" "account queue" detail
   | _ -> fail "expected account CapacityExhausted");
  let mismatch =
    provider_failure
      ~provider:"kimi"
      (Http_client.Capability_mismatch { capability = None })
      "tool stream disabled"
  in
  (match mismatch with
   | Error.InvalidRequest { reason; _ } ->
     check
       bool
       "default capability reason"
       true
       (Agent_sdk.Util.string_contains ~needle:"missing provider capability" reason)
   | _ -> fail "expected InvalidRequest capability mismatch");
  let policy =
    provider_failure
      ~provider:"claude_code"
      (Http_client.Cli_policy_invalid { tool_name = Some "Read"; rule = Some 3 })
      "blocked"
  in
  (match policy with
   | Error.InvalidRequest { reason; _ } ->
     check
       bool
       "policy reason"
       true
       (Agent_sdk.Util.string_contains ~needle:"rule 3" reason)
   | _ -> fail "expected InvalidRequest policy rejection");
  let startup =
    provider_failure
      ~provider:"codex"
      (Http_client.Cli_startup_failed { reason = Http_client.Executable_unavailable })
      "permission denied"
  in
  (match startup with
   | Error.ProviderUnavailable { detail; _ } ->
     check string "startup detail" "executable_unavailable: permission denied" detail
   | _ -> fail "expected ProviderUnavailable startup failure");
  let parse =
    provider_failure (Http_client.Provider_parse_error { parser = None }) "bad JSON"
  in
  (match parse with
   | Error.ParseError { detail } ->
     check string "parser default" "unknown_parser: bad JSON" detail
   | _ -> fail "expected ParseError");
  let wire =
    provider_failure
      ~provider:"glm"
      (Http_client.Provider_wire_error
         { format = Http_client.Sse; kind = Http_client.Malformed_payload })
      "SSE parse failed: bad JSON"
  in
  (match wire with
   | Error.ProviderWireError { provider; format; kind; detail } ->
     check string "wire provider" "glm" provider;
     check string "wire format" "sse" (Http_client.provider_wire_format_to_string format);
     check
       string
       "wire kind"
       "malformed_payload"
       (Http_client.provider_wire_error_kind_to_string kind);
     check string "wire detail" "SSE parse failed: bad JSON" detail
   | _ -> fail "expected typed ProviderWireError");
  let reported =
    provider_failure
      ~provider:"glm"
      (Http_client.Provider_reported_error { error_type = Some "rate_limit_exceeded" })
      "slow down"
  in
  (match reported with
   | Error.ProviderReportedError
       { provider; error_type = Some "rate_limit_exceeded"; detail } ->
     check string "reported provider" "glm" provider;
     check string "reported detail" "slow down" detail
   | _ -> fail "expected typed ProviderReportedError");
  let request_body_limit_message =
    "serialized request body is 2048 bytes, target limit is 1024 bytes"
  in
  let request_body_limit =
    provider_failure
      (Http_client.Request_body_too_large { actual_bytes = 2048; limit_bytes = 1024 })
      request_body_limit_message
  in
  (match request_body_limit with
   | Error.InvalidRequest { reason; _ } ->
     check
       string
       "request-body limit diagnostic is not duplicated"
       request_body_limit_message
       reason
   | _ -> fail "expected InvalidRequest for request-body limit");
  let unknown =
    provider_failure
      ~provider:"unknown-provider"
      (Http_client.Unknown_provider_failure { reason = Some "exit_status" })
      "exited 2"
  in
  match unknown with
  | Error.ProviderUnavailable { detail; _ } ->
    check string "unknown detail" "exit_status: exited 2" detail
  | _ -> fail "expected ProviderUnavailable unknown failure"
;;

let test_provider_failure_empty_completion_maps_to_unavailable () =
  List.iter
    (fun expected ->
       let mapped =
         Error.of_http_error
           ~provider:"openai"
           (Http_client.empty_completion_error ~stop_reason:expected)
       in
       match mapped with
       | Error.ProviderUnavailable { provider; detail } ->
         check string "provider" "openai" provider;
         check bool "nonempty detail" true (String.trim detail <> "")
       | _ -> fail "expected ProviderUnavailable")
    [ Types.EndTurn; Types.MaxTokens ]
;;

let test_http_boundary_remaining_variants_mapping () =
  let accept =
    Error.of_http_error
      ~provider:"anthropic"
      (Http_client.AcceptRejected { reason = "unsupported media type" })
  in
  (match accept with
   | Error.InvalidRequest { reason; _ } ->
     check string "accept rejection" "accept rejected: unsupported media type" reason
   | _ -> fail "expected accept InvalidRequest");
  let terminal_other =
    Error.of_http_error
      ~provider:"codex"
      (Http_client.ProviderTerminal
         { kind = Http_client.Other "cancelled"; message = "operator cancelled" })
  in
  match terminal_other with
  | Error.ProviderTerminal { reason; detail; _ } ->
    check string "terminal reason" "cancelled" reason;
    check string "terminal detail" "operator cancelled" detail
  | _ -> fail "expected ProviderTerminal Other"
;;

let test_is_retryable_matrix () =
  let retryable err = check bool (Error.to_string err) true (Error.is_retryable err) in
  let not_retryable err =
    check bool (Error.to_string err) false (Error.is_retryable err)
  in
  retryable (Error.RateLimit { provider = "p"; retry_after = None; detail = "burst" });
  retryable
    (Error.CapacityExhausted
       { scope = Error.CapacityProvider
       ; affected = [ "p" ]
       ; retry_after = None
       ; detail = "busy"
       });
  retryable
    (Error.ServerError { provider = "p"; code = 503; transient = true; detail = "down" });
  not_retryable
    (Error.ServerError { provider = "p"; code = 500; transient = false; detail = "fatal" });
  retryable
    (Error.NetworkError
       { provider = "p"
       ; kind = Http_client.Connection_refused
       ; timeout_phase = None
       ; detail = "refused"
       });
  not_retryable
    (Error.NetworkError
       { provider = "p"
       ; kind = Http_client.Tls_error
       ; timeout_phase = None
       ; detail = "tls"
       });
  not_retryable
    (Error.NetworkError
       { provider = "p"
       ; kind = Http_client.Local_resource_exhaustion
       ; timeout_phase = None
       ; detail = "fd"
       });
  retryable (Error.Timeout { provider = "p"; timeout_phase = None; detail = "slow" });
  not_retryable
    (Error.HardQuota { provider = "p"; retry_after = None; detail = "billing" });
  not_retryable (Error.ProviderUnavailable { provider = "p"; detail = "missing" });
  not_retryable (Error.AuthError { provider = "p"; detail = "bad key" });
  not_retryable (Error.AuthorizationError { provider = "p"; detail = "forbidden" });
  not_retryable (Error.NotFound { provider = "p"; detail = "model" })
;;

let test_empty_completion_overflow_maps_to_invalid_request () =
  let err =
    Error.of_http_error
      ~provider:"anthropic"
      (Http_client.ProviderFailure
         { kind =
             Http_client.Empty_completion { stop_reason = Types.ContextWindowExceeded }
         ; message = "no content blocks"
         })
  in
  match err with
  | Error.InvalidRequest { provider; reason } ->
    check string "overflow provider" "anthropic" provider;
    let expected =
      Retry.error_message
        (Retry.ContextOverflow
           { message =
               "empty completion (stop_reason=model_context_window_exceeded): no content \
                blocks"
           ; limit = None
           })
    in
    check string "overflow reason" expected reason
  | _ -> fail "expected InvalidRequest for empty completion context overflow"
;;

let test_empty_completion_other_stop_reason_stays_unavailable () =
  let err =
    Error.of_http_error
      ~provider:"anthropic"
      (Http_client.ProviderFailure
         { kind = Http_client.Empty_completion { stop_reason = Types.MaxTokens }
         ; message = "no content blocks"
         })
  in
  match err with
  | Error.ProviderUnavailable { provider; detail = _ } ->
    check string "unavailable provider" "anthropic" provider
  | _ -> fail "expected ProviderUnavailable for non-overflow empty completion"
;;

let () =
  run
    "llm_provider_error"
    [ ( "to_string"
      , [ test_case "MissingApiKey" `Quick test_missing_api_key
        ; test_case "InvalidConfig" `Quick test_invalid_config
        ; test_case "ParseError" `Quick test_parse_error
        ; test_case "UnknownVariant" `Quick test_unknown_variant
        ; test_case "ProviderUnavailable" `Quick test_provider_unavailable
        ; test_case "RateLimit" `Quick test_rate_limit
        ; test_case "HardQuota" `Quick test_hard_quota
        ; test_case "CapacityExhausted" `Quick test_capacity_exhausted
        ; test_case "AuthError" `Quick test_auth_error
        ; test_case "AuthorizationError" `Quick test_authorization_error
        ; test_case "ServerError" `Quick test_server_error
        ; test_case "NetworkError" `Quick test_network_error
        ; test_case "Timeout" `Quick test_timeout
        ; test_case "Timeout phase" `Quick test_timeout_phase
        ; test_case "InvalidRequest" `Quick test_invalid_request
        ; test_case "NotFound" `Quick test_not_found
        ; test_case "ProviderTerminal" `Quick test_provider_terminal
        ] )
    ; ( "mapping"
      , [ test_case "Retry RateLimited" `Quick test_retry_rate_limit_mapping
        ; test_case "Retry rate-limit prose" `Quick test_retry_rate_limit_prose_mapping
        ; test_case "Retry payment required" `Quick test_retry_payment_required_mapping
        ; test_case
            "Retry overloaded unknown provider"
            `Quick
            test_retry_overloaded_unknown_provider_mapping
        ; test_case
            "Empty completion overflow -> InvalidRequest"
            `Quick
            test_empty_completion_overflow_maps_to_invalid_request
        ; test_case
            "Empty completion non-overflow stays ProviderUnavailable"
            `Quick
            test_empty_completion_other_stop_reason_stays_unavailable
        ; test_case "HTTP capacity failure" `Quick test_http_capacity_failure_mapping
        ; test_case "HTTP server error" `Quick test_http_server_error_mapping
        ; test_case "HTTP terminal" `Quick test_http_terminal_mapping
        ; test_case "HTTP network error" `Quick test_http_network_error_mapping
        ; test_case "HTTP timeout error" `Quick test_http_timeout_error_mapping
        ; test_case
            "Retry timeout phase preserved"
            `Quick
            test_retry_timeout_phase_mapping
        ; test_case
            "Retry remaining variants"
            `Quick
            test_retry_remaining_variants_mapping
        ; test_case
            "Provider failure remaining variants"
            `Quick
            test_provider_failure_remaining_variants_mapping
        ; test_case
            "Provider failure empty completion maps to unavailable"
            `Quick
            test_provider_failure_empty_completion_maps_to_unavailable
        ; test_case
            "HTTP boundary remaining variants"
            `Quick
            test_http_boundary_remaining_variants_mapping
        ; test_case "is_retryable matrix" `Quick test_is_retryable_matrix
        ] )
    ]
;;
