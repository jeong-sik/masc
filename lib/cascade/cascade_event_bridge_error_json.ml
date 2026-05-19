let stop_reason_to_wire = function
  | Agent_sdk.Types.EndTurn -> "end_turn"
  | Agent_sdk.Types.StopToolUse -> "tool_use"
  | Agent_sdk.Types.MaxTokens -> "max_tokens"
  | Agent_sdk.Types.StopSequence -> "stop_sequence"
  | Agent_sdk.Types.Unknown value -> value
;;

let agent_completed_usage_fields (response : Agent_sdk.Types.api_response) =
  match response.usage with
  | None -> [ "usage_reported", `Bool false ]
  | Some usage ->
    [ "usage_reported", `Bool true
    ; "input_tokens", `Int usage.input_tokens
    ; "output_tokens", `Int usage.output_tokens
    ; "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
    ; "total_tokens", `Int (usage.input_tokens + usage.output_tokens)
    ; ( "cost_usd"
      , match usage.cost_usd with
        | Some cost -> `Float cost
        | None -> `Null )
    ]
;;

let agent_completed_result_fields = function
  | Ok (response : Agent_sdk.Types.api_response) ->
    [ "success", `Bool true
    ; "result", `String "ok"
    ; "response_id", `String response.id
    ; "model", `String response.model
    ; "stop_reason", `String (stop_reason_to_wire response.stop_reason)
    ]
    @ agent_completed_usage_fields response
  | Error error ->
    [ "success", `Bool false
    ; "result", `String "error"
    ; "error", `String (Agent_sdk.Error.to_string error)
    ; "usage_reported", `Bool false
    ]
;;

let json_float_opt = function
  | Some value -> `Float value
  | None -> `Null
;;

let json_int_opt = function
  | Some value -> `Int value
  | None -> `Null
;;

let json_string_list values = `List (List.map (fun value -> `String value) values)
;;

let network_error_kind_to_wire = function
  | Llm_provider.Http_client.Connection_refused -> "connection_refused"
  | Llm_provider.Http_client.Dns_failure -> "dns_failure"
  | Llm_provider.Http_client.Tls_error -> "tls_error"
  | Llm_provider.Http_client.Timeout -> "timeout"
  | Llm_provider.Http_client.Local_resource_exhaustion -> "local_resource_exhaustion"
  | Llm_provider.Http_client.End_of_file -> "end_of_file"
  | Llm_provider.Http_client.Unknown -> "unknown"
;;

let sdk_api_error_fields = function
  | Agent_sdk.Retry.RateLimited { retry_after; message } ->
    [ "variant", `String "rate_limited"
    ; "message", `String message
    ; "retry_after_s", json_float_opt retry_after
    ]
  | Agent_sdk.Retry.Overloaded { message } ->
    [ "variant", `String "overloaded"; "message", `String message ]
  | Agent_sdk.Retry.ServerError { status; message } ->
    [ "variant", `String "server_error"
    ; "status", `Int status
    ; "message", `String message
    ]
  | Agent_sdk.Retry.AuthError { message } ->
    [ "variant", `String "auth_error"; "message", `String message ]
  | Agent_sdk.Retry.InvalidRequest { message } ->
    [ "variant", `String "invalid_request"; "message", `String message ]
  | Agent_sdk.Retry.NotFound { message } ->
    [ "variant", `String "not_found"; "message", `String message ]
  | Agent_sdk.Retry.ContextOverflow { message; limit } ->
    [ "variant", `String "context_overflow"
    ; "message", `String message
    ; "limit", json_int_opt limit
    ]
  | Agent_sdk.Retry.NetworkError { message; kind } ->
    [ "variant", `String "network_error"
    ; "message", `String message
    ; "network_kind", `String (network_error_kind_to_wire kind)
    ]
  | Agent_sdk.Retry.Timeout { message } ->
    [ "variant", `String "timeout"; "message", `String message ]
;;

let sdk_agent_error_fields = function
  | Agent_sdk.Error.MaxTurnsExceeded { turns; limit } ->
    [ "variant", `String "max_turns_exceeded"; "turns", `Int turns; "limit", `Int limit ]
  | Agent_sdk.Error.TokenBudgetExceeded { kind; used; limit } ->
    [ "variant", `String "token_budget_exceeded"
    ; "kind", `String kind
    ; "used", `Int used
    ; "limit", `Int limit
    ]
  | Agent_sdk.Error.CostBudgetExceeded { spent_usd; limit_usd } ->
    [ "variant", `String "cost_budget_exceeded"
    ; "spent_usd", `Float spent_usd
    ; "limit_usd", `Float limit_usd
    ]
  | Agent_sdk.Error.CostBudgetUnenforceable { model_id = _; limit_usd } ->
    (* RFC-0132 PR-2: event surface model value = external boundary; redact via SSOT.
       The "runtime" JSON key is a schema field name (not a label). *)
    [ "variant", `String "cost_budget_unenforceable"
    ; "runtime",
      `String
        (Boundary_redaction.to_string Boundary_redaction.runtime_model_label)
    ; "limit_usd", `Float limit_usd
    ]
  | Agent_sdk.Error.UnrecognizedStopReason { reason } ->
    [ "variant", `String "unrecognized_stop_reason"; "reason", `String reason ]
  | Agent_sdk.Error.IdleDetected { consecutive_idle_turns } ->
    [ "variant", `String "idle_detected"
    ; "consecutive_idle_turns", `Int consecutive_idle_turns
    ]
  | Agent_sdk.Error.ToolRetryExhausted { attempts; limit; detail } ->
    [ "variant", `String "tool_retry_exhausted"
    ; "attempts", `Int attempts
    ; "limit", `Int limit
    ; "detail", `String detail
    ]
  | Agent_sdk.Error.CompletionContractViolation { contract; reason } ->
    [ "variant", `String "completion_contract_violation"
    ; "contract", `String (Agent_sdk.Completion_contract_id.to_string contract)
    ; "reason", `String reason
    ]
  | Agent_sdk.Error.GuardrailViolation { validator; reason } ->
    [ "variant", `String "guardrail_violation"
    ; "validator", `String validator
    ; "reason", `String reason
    ]
  | Agent_sdk.Error.TripwireViolation { tripwire; reason } ->
    [ "variant", `String "tripwire_violation"
    ; "tripwire", `String tripwire
    ; "reason", `String reason
    ]
  | Agent_sdk.Error.ExitConditionMet { turn } ->
    [ "variant", `String "exit_condition_met"; "turn", `Int turn ]
;;

let sdk_mcp_error_fields = function
  | Agent_sdk.Error.ServerStartFailed { command; detail } ->
    [ "variant", `String "server_start_failed"
    ; "command", `String command
    ; "detail", `String detail
    ]
  | Agent_sdk.Error.InitializeFailed { detail } ->
    [ "variant", `String "initialize_failed"; "detail", `String detail ]
  | Agent_sdk.Error.ToolListFailed { detail } ->
    [ "variant", `String "tool_list_failed"; "detail", `String detail ]
  | Agent_sdk.Error.ToolCallFailed { tool_name; detail } ->
    [ "variant", `String "tool_call_failed"
    ; "tool_name", `String tool_name
    ; "detail", `String detail
    ]
  | Agent_sdk.Error.HttpTransportFailed { url; detail } ->
    [ "variant", `String "http_transport_failed"
    ; "url", `String url
    ; "detail", `String detail
    ]
;;

let sdk_config_error_fields = function
  | Agent_sdk.Error.MissingEnvVar { var_name } ->
    [ "variant", `String "missing_env_var"; "var_name", `String var_name ]
  | Agent_sdk.Error.UnsupportedProvider { detail } ->
    [ "variant", `String "unsupported_provider"; "detail", `String detail ]
  | Agent_sdk.Error.InvalidConfig { field; detail } ->
    [ "variant", `String "invalid_config"
    ; "field", `String field
    ; "detail", `String detail
    ]
;;

let sdk_serialization_error_fields = function
  | Agent_sdk.Error.JsonParseError { detail } ->
    [ "variant", `String "json_parse_error"; "detail", `String detail ]
  | Agent_sdk.Error.VersionMismatch { expected; got } ->
    [ "variant", `String "version_mismatch"; "expected", `Int expected; "got", `Int got ]
  | Agent_sdk.Error.UnknownVariant { type_name; value } ->
    [ "variant", `String "unknown_variant"
    ; "type_name", `String type_name
    ; "value", `String value
    ]
;;

let sdk_io_error_fields = function
  | Agent_sdk.Error.FileOpFailed { op; path; detail } ->
    [ "variant", `String "file_op_failed"
    ; "op", `String op
    ; "path", `String path
    ; "detail", `String detail
    ]
  | Agent_sdk.Error.ValidationFailed { detail } ->
    [ "variant", `String "validation_failed"; "detail", `String detail ]
;;

let sdk_orchestration_error_fields = function
  | Agent_sdk.Error.UnknownAgent { name } ->
    [ "variant", `String "unknown_agent"; "name", `String name ]
  | Agent_sdk.Error.TaskTimeout { task_id } ->
    [ "variant", `String "task_timeout"; "task_id", `String task_id ]
  | Agent_sdk.Error.DiscoveryFailed { url; detail } ->
    [ "variant", `String "discovery_failed"
    ; "url", `String url
    ; "detail", `String detail
    ]
;;

let sdk_a2a_error_fields = function
  | Agent_sdk.Error.TaskNotFound { task_id } ->
    [ "variant", `String "task_not_found"; "task_id", `String task_id ]
  | Agent_sdk.Error.InvalidTransition { task_id; from_state; to_state } ->
    [ "variant", `String "invalid_transition"
    ; "task_id", `String task_id
    ; "from_state", `String from_state
    ; "to_state", `String to_state
    ]
  | Agent_sdk.Error.MessageSendFailed { task_id; detail } ->
    [ "variant", `String "message_send_failed"
    ; "task_id", `String task_id
    ; "detail", `String detail
    ]
  | Agent_sdk.Error.ProtocolError { detail } ->
    [ "variant", `String "protocol_error"; "detail", `String detail ]
  | Agent_sdk.Error.StoreCapacityExceeded { current; max } ->
    [ "variant", `String "store_capacity_exceeded"
    ; "current", `Int current
    ; "max", `Int max
    ]
;;

let sdk_provider_error_fields error =
  let message = Llm_provider.Error.to_string error in
  match error with
  | Llm_provider.Error.MissingApiKey { var_name } ->
    [ "variant", `String "missing_api_key"
    ; "message", `String message
    ; "var_name", `String var_name
    ]
  | Llm_provider.Error.InvalidConfig { field; detail } ->
    [ "variant", `String "invalid_config"
    ; "message", `String message
    ; "field", `String field
    ; "detail", `String detail
    ]
  | Llm_provider.Error.ParseError { detail } ->
    [ "variant", `String "parse_error"
    ; "message", `String message
    ; "detail", `String detail
    ]
  | Llm_provider.Error.UnknownVariant { type_name; value } ->
    [ "variant", `String "unknown_variant"
    ; "message", `String message
    ; "type_name", `String type_name
    ; "value", `String value
    ]
  | Llm_provider.Error.ProviderUnavailable { provider; detail } ->
    [ "variant", `String "provider_unavailable"
    ; "message", `String message
    ; "provider", `String provider
    ; "detail", `String detail
    ]
  | Llm_provider.Error.RateLimit { provider; retry_after; detail } ->
    [ "variant", `String "rate_limited"
    ; "message", `String message
    ; "provider", `String provider
    ; "retry_after_s", json_float_opt retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.HardQuota { provider; retry_after; detail } ->
    [ "variant", `String "hard_quota"
    ; "message", `String message
    ; "provider", `String provider
    ; "retry_after_s", json_float_opt retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.CapacityExhausted
      { scope; affected; retry_after; detail } ->
    [ "variant", `String "capacity_exhausted"
    ; "message", `String message
    ; "capacity_scope", `String (Llm_provider.Error.capacity_scope_to_string scope)
    ; "affected", json_string_list affected
    ; "retry_after_s", json_float_opt retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.AuthError { provider; detail } ->
    [ "variant", `String "auth_error"
    ; "message", `String message
    ; "provider", `String provider
    ; "detail", `String detail
    ]
  | Llm_provider.Error.ServerError { provider; code; transient; detail } ->
    [ "variant", `String "server_error"
    ; "message", `String message
    ; "provider", `String provider
    ; "status", `Int code
    ; "transient", `Bool transient
    ; "detail", `String detail
    ]
  | Llm_provider.Error.NetworkError
      { provider; kind; timeout_phase; detail } ->
    [ "variant", `String "network_error"
    ; "message", `String message
    ; "provider", `String provider
    ; "network_kind", `String (network_error_kind_to_wire kind)
    ; ( "timeout_phase"
      , match timeout_phase with
        | Some phase -> `String (Llm_provider.Http_client.timeout_phase_to_label phase)
        | None -> `Null )
    ; "detail", `String detail
    ]
  | Llm_provider.Error.Timeout { provider; timeout_phase; detail } ->
    [ "variant", `String "timeout"
    ; "message", `String message
    ; "provider", `String provider
    ; ( "timeout_phase"
      , match timeout_phase with
        | Some phase -> `String (Llm_provider.Http_client.timeout_phase_to_label phase)
        | None -> `Null )
    ; "detail", `String detail
    ]
  | Llm_provider.Error.InvalidRequest { provider; reason } ->
    [ "variant", `String "invalid_request"
    ; "message", `String message
    ; "provider", `String provider
    ; "reason", `String reason
    ]
  | Llm_provider.Error.NotFound { provider; detail } ->
    [ "variant", `String "not_found"
    ; "message", `String message
    ; "provider", `String provider
    ; "detail", `String detail
    ]
  | Llm_provider.Error.ProviderTerminal { provider; reason; detail } ->
    [ "variant", `String "provider_terminal"
    ; "message", `String message
    ; "provider", `String provider
    ; "reason", `String reason
    ; "detail", `String detail
    ]
;;

let sdk_error_detail_fields (error : Agent_sdk.Error.sdk_error) =
  match error with
  | Agent_sdk.Error.Api error -> sdk_api_error_fields error
  | Agent_sdk.Error.Provider error -> sdk_provider_error_fields error
  | Agent_sdk.Error.Agent error -> sdk_agent_error_fields error
  | Agent_sdk.Error.Mcp error -> sdk_mcp_error_fields error
  | Agent_sdk.Error.Config error -> sdk_config_error_fields error
  | Agent_sdk.Error.Serialization error -> sdk_serialization_error_fields error
  | Agent_sdk.Error.Io error -> sdk_io_error_fields error
  | Agent_sdk.Error.Orchestration error -> sdk_orchestration_error_fields error
  | Agent_sdk.Error.A2a error -> sdk_a2a_error_fields error
  | Agent_sdk.Error.Internal message ->
    [ "variant", `String "internal"; "message", `String message ]
;;

let sdk_error_json error =
  let domain = Keeper_agent_error.sdk_error_kind error in
  let code =
    Keeper_agent_error.terminal_reason_code_of_sdk_error_typed error
    |> Keeper_turn_terminal_code.to_wire
  in
  `Assoc
    ([ "domain", `String domain
     ; "code", `String code
     ; "retryable", `Bool (Agent_sdk.Error.is_retryable error)
     ]
     @ sdk_error_detail_fields error)
;;

let agent_failed_error_fields error =
  [ "error", `String (Agent_sdk.Error.to_string error)
  ; "error_domain", `String (Keeper_agent_error.sdk_error_kind error)
  ; ( "error_code"
    , `String
        (Keeper_agent_error.terminal_reason_code_of_sdk_error_typed error
         |> Keeper_turn_terminal_code.to_wire) )
  ; "error_retryable", `Bool (Agent_sdk.Error.is_retryable error)
  ; "error_detail", sdk_error_json error
  ]
;;
