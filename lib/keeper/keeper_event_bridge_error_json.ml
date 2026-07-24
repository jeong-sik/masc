let stop_reason_to_wire = Agent_sdk.Types.stop_reason_to_string
let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let agent_completed_usage_fields (response : Agent_sdk.Types.api_response) =
  match response.usage with
  | None -> [ "usage_reported", `Bool false ]
  | Some usage ->
    [ "usage_reported", `Bool true
    ; "input_tokens", `Int usage.input_tokens
    ; "output_tokens", `Int usage.output_tokens
    ; "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
    ; "total_tokens", `Int (Agent_sdk.Types.total_tokens usage)
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

let network_error_kind_to_wire = function
  | Llm_provider.Http_client.Connection_refused -> "connection_refused"
  | Llm_provider.Http_client.Dns_failure -> "dns_failure"
  | Llm_provider.Http_client.Tls_error -> "tls_error"
  | Llm_provider.Http_client.Timeout -> "timeout"
  | Llm_provider.Http_client.Local_resource_exhaustion -> "local_resource_exhaustion"
  | Llm_provider.Http_client.End_of_file -> "end_of_file"
  | Llm_provider.Http_client.Unknown -> "unknown"
;;

let invalid_request_reason_to_wire = function
  | Agent_sdk.Retry.Json_parse_error -> "json_parse_error"
  | Agent_sdk.Retry.Request_body_too_large _ -> "request_body_too_large"
  | Agent_sdk.Retry.Unknown_invalid_request -> "unknown_invalid_request"
;;

let serving_constraint_source_kind_to_wire = function
  | Llm_provider.Serving_constraint.Declaration -> "declaration"
  | Llm_provider.Serving_constraint.Probe -> "probe"
;;

let serving_constraint_confidence_to_wire = function
  | Llm_provider.Serving_constraint.Low -> "low"
  | Llm_provider.Serving_constraint.Medium -> "medium"
  | Llm_provider.Serving_constraint.High -> "high"
;;

let serving_constraint_to_json
      (constraint_ : Llm_provider.Serving_constraint.t)
  =
  let observation = constraint_.observation in
  let evidence = constraint_.evidence in
  `Assoc
    [ "accepted_through", `Int observation.accepted_through
    ; "rejected_from", Json_util.int_opt_to_json observation.rejected_from
    ; "source_kind",
      `String (serving_constraint_source_kind_to_wire evidence.source_kind)
    ; "source_ref", `String evidence.source_ref
    ; "checked_at_unix_s", `Int evidence.checked_at_unix_s
    ; "confidence",
      `String (serving_constraint_confidence_to_wire evidence.confidence)
    ; "expires_at_unix_s", Json_util.int_opt_to_json evidence.expires_at_unix_s
    ]
;;

let input_capacity_reason_to_json = function
  | Agent_sdk.Retry.Serving_constraint_rejected reason ->
    let fields =
      match reason with
      | Llm_provider.Serving_constraint.Evidence_not_yet_valid
          { now_unix_s; checked_at_unix_s } ->
        [ "kind", `String "evidence_not_yet_valid"
        ; "now_unix_s", `Int now_unix_s
        ; "checked_at_unix_s", `Int checked_at_unix_s
        ]
      | Llm_provider.Serving_constraint.Evidence_expired
          { now_unix_s; expires_at_unix_s } ->
        [ "kind", `String "evidence_expired"
        ; "now_unix_s", `Int now_unix_s
        ; "expires_at_unix_s", `Int expires_at_unix_s
        ]
      | Llm_provider.Serving_constraint.Boundary_unknown
          { input_tokens; accepted_through; rejected_from } ->
        [ "kind", `String "boundary_unknown"
        ; "input_tokens", `Int input_tokens
        ; "accepted_through", `Int accepted_through
        ; "rejected_from", Json_util.int_opt_to_json rejected_from
        ]
      | Llm_provider.Serving_constraint.Input_rejected
          { input_tokens; accepted_through; rejected_from } ->
        [ "kind", `String "input_rejected"
        ; "input_tokens", `Int input_tokens
        ; "accepted_through", `Int accepted_through
        ; "rejected_from", `Int rejected_from
        ]
    in
    `Assoc fields
  | Agent_sdk.Retry.Token_measurement_unavailable protocol ->
    `Assoc
      [ "kind", `String "token_measurement_unavailable"
      ; "protocol", `String (Llm_provider.Input_token_count.show_protocol protocol)
      ]
;;

let terminal_effect_disposition_to_wire effect_disposition =
  match Agent_sdk.Error.terminal_effect_disposition effect_disposition with
  | Agent_sdk.Tool_contract.Proven_pre_effect -> "proven_pre_effect"
  | Agent_sdk.Tool_contract.Proven_post_effect -> "proven_post_effect"
  | Agent_sdk.Tool_contract.Effect_outcome_unknown -> "effect_outcome_unknown"
;;

let agent_failed_error_summary = function
  | Agent_sdk.Error.Agent (Agent_sdk.Error.TerminalToolEffectFailed _) ->
    "terminal_tool_effect_failed"
  | Agent_sdk.Error.Agent (Agent_sdk.Error.TerminalToolDurabilityFailed _) ->
    "terminal_tool_durability_failed"
  | Agent_sdk.Error.Agent
      (( Agent_sdk.Error.UnrecognizedStopReason _
       | Agent_sdk.Error.HookExecutionFailed _
       | Agent_sdk.Error.GuardrailViolation _
       | Agent_sdk.Error.TripwireViolation _
       | Agent_sdk.Error.InputRequired _ ) as agent_error) ->
    Agent_sdk.Error.to_string (Agent_sdk.Error.Agent agent_error)
  | ( Agent_sdk.Error.Api _
    | Agent_sdk.Error.Provider _
    | Agent_sdk.Error.Mcp _
    | Agent_sdk.Error.Config _
    | Agent_sdk.Error.Serialization _
    | Agent_sdk.Error.Io _
    | Agent_sdk.Error.Orchestration _
    | Agent_sdk.Error.Internal _ ) as error ->
    Agent_sdk.Error.to_string error
;;

let sdk_api_error_fields = function
  | Agent_sdk.Retry.RateLimited { retry_after; message } ->
    [ "variant", `String "rate_limited"
    ; "message", `String message
    ; "retry_after_s", Json_util.float_opt_to_json retry_after
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
  | Agent_sdk.Retry.AuthorizationError { message } ->
    [ "variant", `String "authorization_error"; "message", `String message ]
  | Agent_sdk.Retry.PaymentRequired { message } ->
    [ "variant", `String "payment_required"; "message", `String message ]
  | Agent_sdk.Retry.InvalidRequest { message; reason } ->
    [ "variant", `String "invalid_request"
    ; "message", `String message
    ; "reason", `String (invalid_request_reason_to_wire reason)
    ]
    @ (match reason with
       | Agent_sdk.Retry.Request_body_too_large { actual_bytes; limit_bytes } ->
         [ "actual_bytes", `Int actual_bytes
         ; "limit_bytes", `Int limit_bytes
         ]
       | Agent_sdk.Retry.Json_parse_error
       | Agent_sdk.Retry.Unknown_invalid_request -> [])
  | Agent_sdk.Retry.NotFound { message } ->
    [ "variant", `String "not_found"; "message", `String message ]
  | Agent_sdk.Retry.ContextOverflow { message; limit } ->
    [ "variant", `String "context_overflow"
    ; "message", `String message
    ; "limit", Json_util.int_opt_to_json limit
    ]
  | Agent_sdk.Retry.InputCapacity { message; constraint_; reason } ->
    [ "variant", `String "input_capacity"
    ; "message", `String message
    ; "constraint", serving_constraint_to_json constraint_
    ; "reason", input_capacity_reason_to_json reason
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
  | Agent_sdk.Error.UnrecognizedStopReason { reason } ->
    [ "variant", `String "unrecognized_stop_reason"; "reason", `String reason ]
  | Agent_sdk.Error.HookExecutionFailed
      { hook_name; stage; tool_name; tool_use_id; detail } ->
    [ "variant", `String "hook_execution_failed"
    ; "hook_name", `String hook_name
    ; "stage", `String stage
    ; "tool_name", Json_util.string_opt_to_json tool_name
    ; "tool_use_id", Json_util.string_opt_to_json tool_use_id
    ; "detail_digest", `String (sha256_hex detail)
    ]
  | Agent_sdk.Error.TerminalToolEffectFailed
      { tool_use_id; effect_disposition; detail } ->
    [ "variant", `String "terminal_tool_effect_failed"
    ; "tool_use_id", `String tool_use_id
    ; ( "effect_disposition"
      , `String (terminal_effect_disposition_to_wire effect_disposition) )
    ; "detail_digest", `String (sha256_hex detail)
    ]
  | Agent_sdk.Error.TerminalToolDurabilityFailed
      { invocation; effect_disposition; detail } ->
    [ "variant", `String "terminal_tool_durability_failed"
    ; ( "tool_use_id"
      , `String (Agent_sdk.Tool_contract.Invocation.tool_use_id invocation) )
    ; "turn", `Int (Agent_sdk.Tool_contract.Invocation.turn invocation)
    ; "planned_index", `Int (Agent_sdk.Tool_contract.Invocation.planned_index invocation)
    ; ( "effect_disposition"
      , `String (terminal_effect_disposition_to_wire effect_disposition) )
    ; "detail_digest", `String (sha256_hex detail)
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
  | Agent_sdk.Error.InputRequired { request_id; participant_name; question; _ } ->
    [ "variant", `String "input_required"
    ; "request_id", `String request_id
    ; "participant_name", Json_util.string_opt_to_json participant_name
    ; "question", `String question
    ]
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
  | Agent_sdk.Error.SensitiveValueInConfig { detail } ->
    [ "variant", `String "sensitive_value_in_config"; "detail", `String detail ]
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
    ; "retry_after_s", Json_util.float_opt_to_json retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.HardQuota { provider; retry_after; detail } ->
    [ "variant", `String "hard_quota"
    ; "message", `String message
    ; "provider", `String provider
    ; "retry_after_s", Json_util.float_opt_to_json retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.CapacityExhausted
      { scope; affected; retry_after; detail } ->
    [ "variant", `String "capacity_backpressure"
    ; "message", `String message
    ; "capacity_scope", `String (Llm_provider.Error.capacity_scope_to_string scope)
    ; "affected", Json_util.json_string_list affected
    ; "retry_after_s", Json_util.float_opt_to_json retry_after
    ; "detail", `String detail
    ]
  | Llm_provider.Error.AuthError { provider; detail } ->
    [ "variant", `String "auth_error"
    ; "message", `String message
    ; "provider", `String provider
    ; "detail", `String detail
    ]
  | Llm_provider.Error.AuthorizationError { provider; detail } ->
    [ "variant", `String "authorization_error"
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

type agent_failed_error_projection =
  { error : string
  ; error_domain : string
  ; error_code : string
  ; error_retryable : bool
  ; error_detail : Yojson.Safe.t
  }

let agent_failed_error_projection error =
  { error = agent_failed_error_summary error
  ; error_domain = Keeper_agent_error.sdk_error_kind error
  ; error_code =
      (Keeper_agent_error.terminal_reason_code_of_sdk_error_typed error
       |> Keeper_turn_terminal_code.to_wire)
  ; error_retryable = Agent_sdk.Error.is_retryable error
  ; error_detail = sdk_error_json error
  }
;;

let agent_failed_error_fields error =
  let projection = agent_failed_error_projection error in
  [ "error", `String projection.error
  ; "error_domain", `String projection.error_domain
  ; "error_code", `String projection.error_code
  ; "error_retryable", `Bool projection.error_retryable
  ; "error_detail", projection.error_detail
  ]
;;
