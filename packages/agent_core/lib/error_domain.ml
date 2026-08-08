(** Fine-grained error domains using polymorphic variants. *)

module Retry = Llm_provider.Retry
module Http_client = Llm_provider.Http_client

type provider_error =
  [ `Rate_limited of float option * string (** retry_after seconds, message *)
  | `Auth_error of string
  | `Authorization_error of string
  | `Server_error of int * string
  | `Network_error of string
  | `Provider_timeout of Http_client.timeout_phase option * string
  | `Streaming_timeout of Http_client.timeout_phase * string
  | `Overloaded
  | `Invalid_request of Llm_provider.Retry.invalid_request_reason * string
  | `Not_found of string
  | `Context_overflow of string * int option
  | `Input_capacity of
      Retry.input_capacity_reason * Llm_provider.Serving_constraint.t * string
  | `Provider_wire_error of
      string
      * Http_client.provider_wire_format
      * Http_client.provider_wire_error_kind
      * string
  | `Provider_reported_error of string * string option * string
  | `Payment_required of string
  ]

type tool_error =
  [ `Tool_exec_failed of string * string
  | `Tool_timeout of string * float
  ]

type agent_error =
  [ `Guardrail_violation of string * string
  | `Tripwire_violation of string * string
  | `Input_required of string * string
  | `Hook_execution_failed of string * string * string option * string option * string
  | `Terminal_tool_effect_failed of string * Error.closed_terminal_effect * string
  | `Terminal_tool_durability_failed of
      Tool_contract.Invocation.t * Error.closed_terminal_effect * string
  | `Unrecognized_stop_reason of string
  ]

type config_error =
  [ `Missing_env_var of string
  | `Unsupported_provider of string
  | `Invalid_config of string * string
  | `Sensitive_value_in_config of string
  ]

type mcp_error =
  [ `Mcp_server_start_failed of string * string
  | `Mcp_init_failed of string
  | `Mcp_tool_list_failed of string
  | `Mcp_tool_call_failed of string * string
  | `Mcp_http_failed of string * string
  ]

type sdk_error_poly =
  [ provider_error
  | tool_error
  | agent_error
  | config_error
  | mcp_error
  | `Serialization of string
  | `Io of string
  | `Orchestration of string
  | `Internal of string
  ]

let is_streaming_timeout_phase = function
  | Http_client.First_token | Http_client.Stream_body | Http_client.Stream_idle _ -> true
  | Http_client.Admission
  | Http_client.Queue
  | Http_client.Wall_clock
  | Http_client.Capacity_backpressure
  | Http_client.Http_operation
  | Http_client.Non_streaming_body
  | Http_client.Provider_step
  | Http_client.Cli_stdout_idle
  | Http_client.Unknown_timeout -> false
;;

(* ── Conversion from Error.sdk_error ────────────────────── *)

let of_api_error (err : Retry.api_error) : provider_error =
  match err with
  | Retry.RateLimited r -> `Rate_limited (r.retry_after, r.message)
  | Retry.AuthError r -> `Auth_error r.message
  | Retry.AuthorizationError r -> `Authorization_error r.message
  | Retry.ServerError r -> `Server_error (r.status, r.message)
  | Retry.NetworkError r -> `Network_error r.message
  | Retry.Timeout r ->
    (match r.phase with
     | Some phase when is_streaming_timeout_phase phase ->
       `Streaming_timeout (phase, r.message)
     | phase -> `Provider_timeout (phase, r.message))
  | Retry.Overloaded _ -> `Overloaded
  | Retry.InvalidRequest r -> `Invalid_request (r.reason, r.message)
  | Retry.NotFound r -> `Not_found r.message
  | Retry.ContextOverflow r -> `Context_overflow (r.message, r.limit)
  | Retry.InputCapacity r -> `Input_capacity (r.reason, r.constraint_, r.message)
  | Retry.PaymentRequired r -> `Payment_required r.message
;;

let of_provider_error (err : Llm_provider.Error.provider_error) : provider_error =
  match err with
  | Llm_provider.Error.RateLimit r -> `Rate_limited (r.retry_after, r.detail)
  | Llm_provider.Error.HardQuota r -> `Rate_limited (r.retry_after, r.detail)
  | Llm_provider.Error.AuthError r -> `Auth_error r.detail
  | Llm_provider.Error.AuthorizationError r -> `Authorization_error r.detail
  | Llm_provider.Error.ServerError r -> `Server_error (r.code, r.detail)
  | Llm_provider.Error.NetworkError r -> `Network_error r.detail
  | Llm_provider.Error.Timeout r ->
    (match r.timeout_phase with
     | Some phase when is_streaming_timeout_phase phase ->
       `Streaming_timeout (phase, r.detail)
     | phase -> `Provider_timeout (phase, r.detail))
  | Llm_provider.Error.CapacityExhausted _ -> `Overloaded
  | Llm_provider.Error.InvalidRequest r ->
    `Invalid_request (Retry.Unknown_invalid_request, r.reason)
  | Llm_provider.Error.NotFound r -> `Not_found r.detail
  | Llm_provider.Error.MissingApiKey r ->
    `Auth_error (Printf.sprintf "missing API key: %s" r.var_name)
  | Llm_provider.Error.InvalidConfig r ->
    `Invalid_request (Retry.Unknown_invalid_request, r.detail)
  | Llm_provider.Error.ParseError r ->
    `Invalid_request (Retry.Unknown_invalid_request, r.detail)
  | Llm_provider.Error.ProviderWireError r ->
    `Provider_wire_error (r.provider, r.format, r.kind, r.detail)
  | Llm_provider.Error.ProviderReportedError r ->
    `Provider_reported_error (r.provider, r.error_type, r.detail)
  | Llm_provider.Error.UnknownVariant r ->
    `Invalid_request
      ( Retry.Unknown_invalid_request
      , Printf.sprintf "unknown %s variant: %s" r.type_name r.value )
  | Llm_provider.Error.ProviderUnavailable r -> `Network_error r.detail
  | Llm_provider.Error.ProviderTerminal r ->
    `Invalid_request
      (Retry.Unknown_invalid_request, Printf.sprintf "%s: %s" r.reason r.detail)
;;

let of_sdk_error (err : Error.sdk_error) : sdk_error_poly =
  match err with
  | Error.Api err -> (of_api_error err :> sdk_error_poly)
  | Error.Provider err -> (of_provider_error err :> sdk_error_poly)
  | Error.Agent (GuardrailViolation r) -> `Guardrail_violation (r.validator, r.reason)
  | Error.Agent (TripwireViolation r) -> `Tripwire_violation (r.tripwire, r.reason)
  | Error.Agent (InputRequired r) -> `Input_required (r.request_id, r.question)
  | Error.Agent (HookExecutionFailed r) ->
    `Hook_execution_failed (r.hook_name, r.stage, r.tool_name, r.tool_use_id, r.detail)
  | Error.Agent (TerminalToolEffectFailed r) ->
    `Terminal_tool_effect_failed (r.tool_use_id, r.effect_disposition, r.detail)
  | Error.Agent (TerminalToolDurabilityFailed r) ->
    `Terminal_tool_durability_failed (r.invocation, r.effect_disposition, r.detail)
  | Error.Agent (UnrecognizedStopReason r) -> `Unrecognized_stop_reason r.reason
  | Error.Config (MissingEnvVar r) -> `Missing_env_var r.var_name
  | Error.Config (UnsupportedProvider r) -> `Unsupported_provider r.detail
  | Error.Config (InvalidConfig r) -> `Invalid_config (r.field, r.detail)
  | Error.Config (SensitiveValueInConfig r) -> `Sensitive_value_in_config r.detail
  | Error.Mcp (ServerStartFailed r) -> `Mcp_server_start_failed (r.command, r.detail)
  | Error.Mcp (InitializeFailed r) -> `Mcp_init_failed r.detail
  | Error.Mcp (ToolListFailed r) -> `Mcp_tool_list_failed r.detail
  | Error.Mcp (ToolCallFailed r) -> `Mcp_tool_call_failed (r.tool_name, r.detail)
  | Error.Mcp (HttpTransportFailed r) -> `Mcp_http_failed (r.url, r.detail)
  | Error.Serialization e -> `Serialization (Error.to_string (Error.Serialization e))
  | Error.Io e -> `Io (Error.to_string (Error.Io e))
  | Error.Orchestration e -> `Orchestration (Error.to_string (Error.Orchestration e))
  | Error.Internal s -> `Internal s
;;

(* ── Conversion back to Error.sdk_error ─────────────────── *)

let provider_to_sdk : provider_error -> Error.sdk_error = function
  | `Rate_limited (after, message) ->
    Error.Api (Retry.RateLimited { retry_after = after; message })
  | `Auth_error msg -> Error.Api (Retry.AuthError { message = msg })
  | `Authorization_error msg -> Error.Api (Retry.AuthorizationError { message = msg })
  | `Server_error (status, msg) -> Error.Api (Retry.ServerError { status; message = msg })
  | `Network_error msg -> Error.Api (Retry.NetworkError { message = msg; kind = Unknown })
  | `Provider_timeout (phase, msg) -> Error.Api (Retry.Timeout { message = msg; phase })
  | `Streaming_timeout (phase, msg) ->
    Error.Provider
      (Llm_provider.Error.Timeout
         { provider = "unknown"; timeout_phase = Some phase; detail = msg })
  | `Overloaded -> Error.Api (Retry.Overloaded { message = "overloaded" })
  (* The reverse direction used to overwrite the reason with
     Unknown_invalid_request, so a round trip through this module erased a typed
     capacity refusal even when the forward direction had carried it. *)
  | `Invalid_request (reason, msg) ->
    Error.Api (Retry.InvalidRequest { message = msg; reason })
  | `Not_found msg -> Error.Api (Retry.NotFound { message = msg })
  | `Context_overflow (msg, limit) ->
    Error.Api (Retry.ContextOverflow { message = msg; limit })
  | `Input_capacity (reason, constraint_, message) ->
    Error.Api (Retry.InputCapacity { message; constraint_; reason })
  | `Provider_wire_error (provider, format, kind, detail) ->
    Error.Provider
      (Llm_provider.Error.ProviderWireError { provider; format; kind; detail })
  | `Provider_reported_error (provider, error_type, detail) ->
    Error.Provider
      (Llm_provider.Error.ProviderReportedError { provider; error_type; detail })
  | `Payment_required msg -> Error.Api (Retry.PaymentRequired { message = msg })
;;

let to_sdk_error (err : sdk_error_poly) : Error.sdk_error =
  match err with
  | #provider_error as e -> provider_to_sdk e
  | `Guardrail_violation (validator, reason) ->
    Error.Agent (GuardrailViolation { validator; reason })
  | `Tripwire_violation (tripwire, reason) ->
    Error.Agent (TripwireViolation { tripwire; reason })
  | `Input_required (request_id, question) ->
    Error.Agent
      (InputRequired
         { request_id
         ; participant_name = None
         ; question
         ; schema = None
         ; timeout_s = None
         ; created_at = Unix.gettimeofday ()
         })
  | `Hook_execution_failed (hook_name, stage, tool_name, tool_use_id, detail) ->
    Error.Agent (HookExecutionFailed { hook_name; stage; tool_name; tool_use_id; detail })
  | `Terminal_tool_effect_failed (tool_use_id, effect_disposition, detail) ->
    Error.Agent (TerminalToolEffectFailed { tool_use_id; effect_disposition; detail })
  | `Terminal_tool_durability_failed (invocation, effect_disposition, detail) ->
    Error.Agent (TerminalToolDurabilityFailed { invocation; effect_disposition; detail })
  | `Unrecognized_stop_reason reason -> Error.Agent (UnrecognizedStopReason { reason })
  | `Missing_env_var var -> Error.Config (MissingEnvVar { var_name = var })
  | `Unsupported_provider detail -> Error.Config (UnsupportedProvider { detail })
  | `Invalid_config (field, detail) -> Error.Config (InvalidConfig { field; detail })
  | `Sensitive_value_in_config detail -> Error.Config (SensitiveValueInConfig { detail })
  | `Mcp_server_start_failed (command, detail) ->
    Error.Mcp (ServerStartFailed { command; detail })
  | `Mcp_init_failed detail -> Error.Mcp (InitializeFailed { detail })
  | `Mcp_tool_list_failed detail -> Error.Mcp (ToolListFailed { detail })
  | `Mcp_tool_call_failed (tool_name, detail) ->
    Error.Mcp (ToolCallFailed { tool_name; detail })
  | `Mcp_http_failed (url, detail) -> Error.Mcp (HttpTransportFailed { url; detail })
  | `Tool_exec_failed (_name, detail) ->
    Error.Internal (Printf.sprintf "Tool execution failed: %s" detail)
  | `Tool_timeout (name, elapsed) ->
    Error.Internal (Printf.sprintf "Tool %s timed out after %.1fs" name elapsed)
  | `Serialization detail -> Error.Serialization (JsonParseError { detail })
  | `Io detail -> Error.Io (ValidationFailed { detail })
  | `Orchestration detail -> Error.Internal detail
  | `Internal s -> Error.Internal s
;;

(* ── Error with context (moonpool Exn_bt.t inspired) ────── *)

type error_ctx =
  { error : sdk_error_poly
  ; stage : string option
  ; backtrace : string option
  }

let with_stage stage error = { error; stage = Some stage; backtrace = None }

(* ── String / retryable ─────────────────────────────────── *)

let to_string (err : [< sdk_error_poly ]) : string =
  to_sdk_error (err :> sdk_error_poly) |> Error.to_string
;;

let is_retryable (err : [< sdk_error_poly ]) : bool =
  match (err :> sdk_error_poly) with
  | `Rate_limited _
  | `Server_error _
  | `Overloaded
  | `Provider_timeout _
  | `Streaming_timeout _
  | `Network_error _ -> true
  | `Mcp_init_failed _
  | `Mcp_tool_list_failed _
  | `Mcp_tool_call_failed _
  | `Mcp_http_failed _ -> true
  (* Non-retryable: enumerated explicitly (no [_] catch-all) so a future
     sdk_error_poly tag triggers a partial-match compiler warning instead of
     being silently treated as non-retryable. error_domain.mli's purpose is to
     eliminate defensive catch-alls; this matches the exhaustive sibling
     Error.is_retryable. *)
  | `Auth_error _
  | `Authorization_error _
  | `Invalid_request _
  | `Not_found _
  | `Context_overflow _
  | `Input_capacity _
  | `Provider_wire_error _
  | `Provider_reported_error _
  | `Payment_required _
  | `Tool_exec_failed _
  | `Tool_timeout _
  | `Guardrail_violation _
  | `Tripwire_violation _
  | `Input_required _
  | `Hook_execution_failed _
  | `Terminal_tool_effect_failed _
  | `Terminal_tool_durability_failed _
  | `Unrecognized_stop_reason _
  | `Missing_env_var _
  | `Unsupported_provider _
  | `Invalid_config _
  | `Sensitive_value_in_config _
  | `Mcp_server_start_failed _
  | `Serialization _
  | `Io _
  | `Orchestration _
  | `Internal _ -> false
;;

let ctx_to_string (ctx : error_ctx) : string =
  let base = to_string ctx.error in
  match ctx.stage with
  | Some stage -> Printf.sprintf "[%s] %s" stage base
  | None -> base
;;
