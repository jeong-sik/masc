let stop_reason_to_wire = Agent_core.Types.stop_reason_to_string
let sha256_hex value = Digestif.SHA256.(digest_string value |> to_hex)

let agent_completed_usage_fields (response : Agent_core.Types.api_response) =
  match response.usage with
  | None ->
    [ "usage_reported", `Bool false
    ; "usage_projection", `String "raw_observation"
    ]
  | Some usage ->
    [ "usage_reported", `Bool true
    ; "usage_projection", `String "raw_observation"
    ; "input_tokens", `Int usage.input_tokens
    ; "output_tokens", `Int usage.output_tokens
    ; "cache_creation_input_tokens", `Int usage.cache_creation_input_tokens
    ; "cache_read_input_tokens", `Int usage.cache_read_input_tokens
    ; "total_tokens", `Int (Agent_core.Types.total_tokens usage)
    ; ( "cost_usd"
      , match usage.cost_usd with
        | Some cost -> `Float cost
        | None -> `Null )
    ]
;;

let agent_completed_response_fields (response : Agent_core.Types.api_response) =
  [ "success", `Bool true
  ; "result", `String "ok"
  ; "response_id", `String response.id
  ; "model", `String response.model
  ; "stop_reason", `String (stop_reason_to_wire response.stop_reason)
  ]
  @ agent_completed_usage_fields response
;;

let invalid_request_reason_to_wire = function
  | Agent_core.Retry.Json_parse_error -> "json_parse_error"
  | Agent_core.Retry.Attempt_rejected -> "attempt_rejected"
  | Agent_core.Retry.Request_body_too_large _ -> "request_body_too_large"
  | Agent_core.Retry.Request_body_refused_by_provider _ ->
    "request_body_refused_by_provider"
  | Agent_core.Retry.Unknown_invalid_request -> "unknown_invalid_request"
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
  | Agent_core.Retry.Serving_constraint_rejected reason ->
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
  | Agent_core.Retry.Token_measurement_unavailable protocol ->
    `Assoc
      [ "kind", `String "token_measurement_unavailable"
      ; "protocol", `String (Llm_provider.Input_token_count.show_protocol protocol)
      ]
;;

let agent_failed_error_summary = function
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolEffectFailed _) ->
    "terminal_tool_effect_failed"
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolDurabilityFailed _) ->
    "terminal_tool_durability_failed"
  | Agent_core.Error.Agent
      (( Agent_core.Error.UnrecognizedStopReason _
       | Agent_core.Error.ToolRoundLimitExceeded _
       | Agent_core.Error.HookExecutionFailed _
       | Agent_core.Error.GuardrailViolation _
       | Agent_core.Error.TripwireViolation _
       | Agent_core.Error.InputRequired _ ) as agent_error) ->
    Agent_core.Error.to_string (Agent_core.Error.Agent agent_error)
  | ( Agent_core.Error.Api _
    | Agent_core.Error.Provider _
    | Agent_core.Error.Mcp _
    | Agent_core.Error.Config _
    | Agent_core.Error.Serialization _
    | Agent_core.Error.Io _
    | Agent_core.Error.Orchestration _
    | Agent_core.Error.Internal _
    | Agent_core.Error.Internal_carried _ ) as error ->
    Agent_core.Error.to_string error
;;

let core_api_error_fields = function
  | Agent_core.Retry.RateLimited { retry_after; message } ->
    [ "variant", `String "rate_limited"
    ; "message", `String message
    ; "retry_after_s", Json_util.float_opt_to_json retry_after
    ]
  | Agent_core.Retry.Overloaded { message } ->
    [ "variant", `String "overloaded"; "message", `String message ]
  | Agent_core.Retry.ServerError { status; message } ->
    [ "variant", `String "server_error"
    ; "status", `Int status
    ; "message", `String message
    ]
  | Agent_core.Retry.AuthError { message } ->
    [ "variant", `String "auth_error"; "message", `String message ]
  | Agent_core.Retry.AuthorizationError { message } ->
    [ "variant", `String "authorization_error"; "message", `String message ]
  | Agent_core.Retry.PaymentRequired { message } ->
    [ "variant", `String "payment_required"; "message", `String message ]
  | Agent_core.Retry.InvalidRequest { message; reason } ->
    [ "variant", `String "invalid_request"
    ; "message", `String message
    ; "reason", `String (invalid_request_reason_to_wire reason)
    ]
    @ (match reason with
       | Agent_core.Retry.Request_body_too_large { actual_bytes; limit_bytes } ->
         [ "actual_bytes", `Int actual_bytes
         ; "limit_bytes", `Int limit_bytes
         ]
       | Agent_core.Retry.Request_body_refused_by_provider { status } ->
         [ "status", `Int status ]
       | Agent_core.Retry.Json_parse_error
       | Agent_core.Retry.Attempt_rejected
       | Agent_core.Retry.Unknown_invalid_request -> [])
  | Agent_core.Retry.NotFound { message } ->
    [ "variant", `String "not_found"; "message", `String message ]
  | Agent_core.Retry.ContextOverflow { message; limit } ->
    [ "variant", `String "context_overflow"
    ; "message", `String message
    ; "limit", Json_util.int_opt_to_json limit
    ]
  | Agent_core.Retry.InputCapacity { message; constraint_; reason } ->
    [ "variant", `String "input_capacity"
    ; "message", `String message
    ; "constraint", serving_constraint_to_json constraint_
    ; "reason", input_capacity_reason_to_json reason
    ]
  | Agent_core.Retry.NetworkError { message; kind } ->
    [ "variant", `String "network_error"
    ; "message", `String message
    ; "network_kind", `String (Keeper_agent_error.network_error_kind_to_wire kind)
    ]
  | Agent_core.Retry.Timeout { message; phase } ->
    [ "variant", `String "timeout"
    ; "message", `String message
    ; ( "timeout_phase"
      , Json_util.string_opt_to_json
          (Option.map Llm_provider.Http_client.timeout_phase_to_label phase) )
    ]
;;

let core_agent_error_fields = function
  | Agent_core.Error.UnrecognizedStopReason { reason } ->
    [ "variant", `String "unrecognized_stop_reason"; "reason", `String reason ]
  | Agent_core.Error.ToolRoundLimitExceeded { rounds; limit } ->
    [ "variant", `String "tool_round_limit_exceeded"
    ; "rounds", `Int rounds
    ; "limit", `Int limit
    ]
  | Agent_core.Error.HookExecutionFailed
      { hook_name; stage; tool_name; tool_use_id; detail } ->
    [ "variant", `String "hook_execution_failed"
    ; "hook_name", `String hook_name
    ; "stage", `String stage
    ; "tool_name", Json_util.string_opt_to_json tool_name
    ; "tool_use_id", Json_util.string_opt_to_json tool_use_id
    ; "detail_digest", `String (sha256_hex detail)
    ]
  | Agent_core.Error.TerminalToolEffectFailed
      { tool_use_id; effect_disposition; detail } ->
    [ "variant", `String "terminal_tool_effect_failed"
    ; "tool_use_id", `String tool_use_id
    ; ( "effect_disposition"
      , `String (Keeper_agent_error.terminal_effect_disposition_to_wire effect_disposition) )
    ; "detail_digest", `String (sha256_hex detail)
    ]
  | Agent_core.Error.TerminalToolDurabilityFailed
      { invocation; effect_disposition; detail } ->
    let schedule = Agent_core.Tool_contract.Invocation.schedule invocation in
    [ "variant", `String "terminal_tool_durability_failed"
    ; ( "tool_use_id"
      , `String (Agent_core.Tool_contract.Invocation.tool_use_id invocation) )
    ; "turn", `Int (Agent_core.Tool_contract.Invocation.turn invocation)
    ; "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; ( "execution_mode"
      , Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode )
    ; ( "effect_disposition"
      , `String (Keeper_agent_error.terminal_effect_disposition_to_wire effect_disposition) )
    ; "detail_digest", `String (sha256_hex detail)
    ]
  | Agent_core.Error.GuardrailViolation { validator; reason } ->
    [ "variant", `String "guardrail_violation"
    ; "validator", `String validator
    ; "reason", `String reason
    ]
  | Agent_core.Error.TripwireViolation { tripwire; reason } ->
    [ "variant", `String "tripwire_violation"
    ; "tripwire", `String tripwire
    ; "reason", `String reason
    ]
  | Agent_core.Error.InputRequired { request_id; participant_name; question; _ } ->
    [ "variant", `String "input_required"
    ; "request_id", `String request_id
    ; "participant_name", Json_util.string_opt_to_json participant_name
    ; "question", `String question
    ]
;;

let core_mcp_error_fields = function
  | Agent_core.Error.ServerStartFailed { command; detail } ->
    [ "variant", `String "server_start_failed"
    ; "command", `String command
    ; "detail", `String detail
    ]
  | Agent_core.Error.InitializeFailed { detail } ->
    [ "variant", `String "initialize_failed"; "detail", `String detail ]
  | Agent_core.Error.ToolListFailed { detail } ->
    [ "variant", `String "tool_list_failed"; "detail", `String detail ]
  | Agent_core.Error.ToolCallFailed { tool_name; detail } ->
    [ "variant", `String "tool_call_failed"
    ; "tool_name", `String tool_name
    ; "detail", `String detail
    ]
  | Agent_core.Error.HttpTransportFailed { url; detail } ->
    [ "variant", `String "http_transport_failed"
    ; "url", `String url
    ; "detail", `String detail
    ]
;;

let core_config_error_fields = function
  | Agent_core.Error.MissingEnvVar { var_name } ->
    [ "variant", `String "missing_env_var"; "var_name", `String var_name ]
  | Agent_core.Error.UnsupportedProvider { detail } ->
    [ "variant", `String "unsupported_provider"; "detail", `String detail ]
  | Agent_core.Error.CredentialUnavailable { provider_id; carrier } ->
    [ "variant", `String "credential_unavailable"
    ; "provider_id", `String provider_id
    ; ( "carrier"
      , `String
          (match carrier with
           | Agent_core.Error.InlineCredential -> "inline"
           | Agent_core.Error.FileCredential -> "file") )
    ]
  | Agent_core.Error.InvalidConfig { field; detail } ->
    [ "variant", `String "invalid_config"
    ; "field", `String field
    ; "detail", `String detail
    ]
  | Agent_core.Error.SensitiveValueInConfig { detail } ->
    [ "variant", `String "sensitive_value_in_config"; "detail", `String detail ]
;;

let core_serialization_error_fields = function
  | Agent_core.Error.JsonParseError { detail } ->
    [ "variant", `String "json_parse_error"; "detail", `String detail ]
  | Agent_core.Error.VersionMismatch { expected; got } ->
    [ "variant", `String "version_mismatch"; "expected", `Int expected; "got", `Int got ]
  | Agent_core.Error.UnknownVariant { type_name; value } ->
    [ "variant", `String "unknown_variant"
    ; "type_name", `String type_name
    ; "value", `String value
    ]
;;

let core_io_error_fields = function
  | Agent_core.Error.FileOpFailed { op; path; detail } ->
    [ "variant", `String "file_op_failed"
    ; "op", `String op
    ; "path", `String path
    ; "detail", `String detail
    ]
  | Agent_core.Error.ValidationFailed { detail } ->
    [ "variant", `String "validation_failed"; "detail", `String detail ]
;;

let core_orchestration_error_fields = function
  | Agent_core.Error.UnknownAgent { name } ->
    [ "variant", `String "unknown_agent"; "name", `String name ]
  | Agent_core.Error.TaskTimeout { task_id } ->
    [ "variant", `String "task_timeout"; "task_id", `String task_id ]
  | Agent_core.Error.DiscoveryFailed { url; detail } ->
    [ "variant", `String "discovery_failed"
    ; "url", `String url
    ; "detail", `String detail
    ]
;;

let core_provider_error_fields error =
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
  | Llm_provider.Error.ProviderWireError { provider; format; kind; detail } ->
    [ "variant", `String "provider_wire_error"
    ; "message", `String message
    ; "provider", `String provider
    ; "format", `String (Llm_provider.Http_client.provider_wire_format_to_string format)
    ; "wire_kind", `String (Llm_provider.Http_client.provider_wire_error_kind_to_string kind)
    ; "detail", `String detail
    ]
  | Llm_provider.Error.ProviderReportedError { provider; error_type; detail } ->
    [ "variant", `String "provider_reported_error"
    ; "message", `String message
    ; "provider", `String provider
    ; ( "error_type"
      , match error_type with
        | Some error_type -> `String error_type
        | None -> `Null )
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
    ; "network_kind", `String (Keeper_agent_error.network_error_kind_to_wire kind)
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

let core_error_detail_fields (error : Agent_core.Error.t) =
  match error with
  | Agent_core.Error.Api error -> core_api_error_fields error
  | Agent_core.Error.Provider error -> core_provider_error_fields error
  | Agent_core.Error.Agent error -> core_agent_error_fields error
  | Agent_core.Error.Mcp error -> core_mcp_error_fields error
  | Agent_core.Error.Config error -> core_config_error_fields error
  | Agent_core.Error.Serialization error -> core_serialization_error_fields error
  | Agent_core.Error.Io error -> core_io_error_fields error
  | Agent_core.Error.Orchestration error -> core_orchestration_error_fields error
  | Agent_core.Error.Internal message | Agent_core.Error.Internal_carried { message = message; _ } ->
    [ "variant", `String "internal"; "message", `String message ]
;;

let core_error_json error =
  let domain = Agent_core.Error.(category error |> category_label) in
  let code =
    Keeper_agent_error.terminal_reason_code_of_core_error_typed error
    |> Keeper_turn_terminal_code.to_wire
  in
  `Assoc
    ([ "domain", `String domain
     ; "code", `String code
     ; "retryable", `Bool (Agent_core.Error.is_retryable error)
     ]
     @ core_error_detail_fields error)
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
  ; error_domain = Agent_core.Error.(category error |> category_label)
  ; error_code =
      (Keeper_agent_error.terminal_reason_code_of_core_error_typed error
       |> Keeper_turn_terminal_code.to_wire)
  ; error_retryable = Agent_core.Error.is_retryable error
  ; error_detail = core_error_json error
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
