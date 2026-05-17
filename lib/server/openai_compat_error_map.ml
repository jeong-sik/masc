(** RFC-0105 — see [.mli] for contract. *)

type http_status =
  [ `Bad_request
  | `Unauthorized
  | `Not_found
  | `Request_timeout
  | `Too_many_requests
  | `Internal_server_error
  | `Bad_gateway
  | `Service_unavailable
  | `Gateway_timeout
  ]

type t = {
  http_status : http_status;
  openai_kind : string;
  openai_code : string option;
  message     : string;
}

(* OpenAI error "type" field canonical values.
   Reference: OpenAI Platform docs § Errors. *)
let kind_invalid_request   = "invalid_request_error"
let kind_authentication    = "authentication_error"
let kind_permission        = "permission_error"
let kind_not_found         = "not_found_error"
let kind_rate_limit        = "rate_limit_error"
let kind_server            = "server_error"

let of_api_error (e : Agent_sdk.Error.Retry.api_error) : t =
  let module R = Agent_sdk.Error.Retry in
  let message = R.error_message e in
  match e with
  | R.RateLimited _ ->
    { http_status = `Too_many_requests
    ; openai_kind = kind_rate_limit
    ; openai_code = Some "rate_limited"
    ; message }
  | R.Overloaded _ ->
    { http_status = `Service_unavailable
    ; openai_kind = kind_server
    ; openai_code = Some "overloaded"
    ; message }
  | R.ServerError { status; _ } ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some (Printf.sprintf "upstream_%d" status)
    ; message }
  | R.AuthError _ ->
    { http_status = `Unauthorized
    ; openai_kind = kind_authentication
    ; openai_code = Some "invalid_api_key"
    ; message }
  | R.InvalidRequest _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "invalid_request"
    ; message }
  | R.NotFound _ ->
    { http_status = `Not_found
    ; openai_kind = kind_not_found
    ; openai_code = Some "model_not_found"
    ; message }
  | R.ContextOverflow _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "context_length_exceeded"
    ; message }
  | R.NetworkError _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "network_error"
    ; message }
  | R.Timeout _ ->
    { http_status = `Gateway_timeout
    ; openai_kind = kind_server
    ; openai_code = Some "timeout"
    ; message }

let of_agent_error (e : Agent_sdk.Error.agent_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Agent e) in
  match e with
  | Agent_sdk.Error.MaxTurnsExceeded _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "max_turns_exceeded"
    ; message }
  | TokenBudgetExceeded _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "token_budget_exceeded"
    ; message }
  | CostBudgetExceeded _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "cost_budget_exceeded"
    ; message }
  | CostBudgetUnenforceable _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "cost_budget_unenforceable"
    ; message }
  | UnrecognizedStopReason _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "unrecognized_stop_reason"
    ; message }
  | IdleDetected _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "idle_detected"
    ; message }
  | ToolRetryExhausted _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "tool_retry_exhausted"
    ; message }
  | CompletionContractViolation _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "completion_contract_violation"
    ; message }
  | GuardrailViolation _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "guardrail_violation"
    ; message }
  | TripwireViolation _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "tripwire_violation"
    ; message }
  | ExitConditionMet _ ->
    (* Non-fatal — the agent stopped voluntarily. Surface as 500 so the
       client doesn't silently treat it as success, but tag a distinct code
       so observability can filter. *)
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "exit_condition_met"
    ; message }

let of_mcp_error (e : Agent_sdk.Error.mcp_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Mcp e) in
  match e with
  | Agent_sdk.Error.ServerStartFailed _ ->
    { http_status = `Service_unavailable
    ; openai_kind = kind_server
    ; openai_code = Some "mcp_server_start_failed"
    ; message }
  | InitializeFailed _ ->
    { http_status = `Service_unavailable
    ; openai_kind = kind_server
    ; openai_code = Some "mcp_initialize_failed"
    ; message }
  | ToolListFailed _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "mcp_tool_list_failed"
    ; message }
  | ToolCallFailed _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "mcp_tool_call_failed"
    ; message }
  | HttpTransportFailed _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "mcp_http_transport_failed"
    ; message }

let of_config_error (e : Agent_sdk.Error.config_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Config e) in
  match e with
  | Agent_sdk.Error.MissingEnvVar _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "config_missing_env"
    ; message }
  | UnsupportedProvider _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "unsupported_provider"
    ; message }
  | InvalidConfig _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "config_invalid"
    ; message }

let of_serialization_error (e : Agent_sdk.Error.serialization_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Serialization e) in
  match e with
  | Agent_sdk.Error.JsonParseError _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "json_parse_error"
    ; message }
  | VersionMismatch _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "version_mismatch"
    ; message }
  | UnknownVariant _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "unknown_variant"
    ; message }

let of_io_error (e : Agent_sdk.Error.io_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Io e) in
  match e with
  | Agent_sdk.Error.FileOpFailed _ ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "io_file_op_failed"
    ; message }
  | ValidationFailed _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "validation_failed"
    ; message }

let of_orchestration_error (e : Agent_sdk.Error.orchestration_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.Orchestration e) in
  match e with
  | Agent_sdk.Error.UnknownAgent _ ->
    { http_status = `Not_found
    ; openai_kind = kind_not_found
    ; openai_code = Some "agent_not_found"
    ; message }
  | TaskTimeout _ ->
    { http_status = `Gateway_timeout
    ; openai_kind = kind_server
    ; openai_code = Some "task_timeout"
    ; message }
  | DiscoveryFailed _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "discovery_failed"
    ; message }

let of_a2a_error (e : Agent_sdk.Error.a2a_error) : t =
  let message = Agent_sdk.Error.to_string (Agent_sdk.Error.A2a e) in
  match e with
  | Agent_sdk.Error.TaskNotFound _ ->
    { http_status = `Not_found
    ; openai_kind = kind_not_found
    ; openai_code = Some "task_not_found"
    ; message }
  | InvalidTransition _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "invalid_transition"
    ; message }
  | MessageSendFailed _ ->
    { http_status = `Bad_gateway
    ; openai_kind = kind_server
    ; openai_code = Some "message_send_failed"
    ; message }
  | ProtocolError _ ->
    { http_status = `Bad_request
    ; openai_kind = kind_invalid_request
    ; openai_code = Some "protocol_error"
    ; message }
  | StoreCapacityExceeded _ ->
    { http_status = `Service_unavailable
    ; openai_kind = kind_server
    ; openai_code = Some "store_capacity_exceeded"
    ; message }

let of_sdk_error (e : Agent_sdk.Error.sdk_error) : t =
  match e with
  | Agent_sdk.Error.Api ae -> of_api_error ae
  | Agent ae -> of_agent_error ae
  | Mcp me -> of_mcp_error me
  | Config ce -> of_config_error ce
  | Serialization se -> of_serialization_error se
  | Io ioe -> of_io_error ioe
  | Orchestration oe -> of_orchestration_error oe
  | A2a ae -> of_a2a_error ae
  | Internal msg ->
    { http_status = `Internal_server_error
    ; openai_kind = kind_server
    ; openai_code = Some "internal_error"
    ; message = msg }

(* Mark [kind_permission] referenced so future variants needing 403 do not
   trip the unused-warning. RFC-0105 acceptance leaves the symbol exposed
   intentionally; remove only if no 403 variant materializes. *)
let _ = kind_permission
