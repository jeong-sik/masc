(** Error translation helpers for keeper Agent.run orchestration. *)

let sdk_error_kind = function
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Provider _ -> "provider"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.Internal _ -> "internal"
;;

let sdk_error_kind_for_receipt err =
  Keeper_execution_receipt.error_kind_of_string (sdk_error_kind err)
;;

let network_error_kind_user_label = function
  | Llm_provider.Http_client.Connection_refused -> "connection refused"
  | Llm_provider.Http_client.Dns_failure -> "DNS lookup failed"
  | Llm_provider.Http_client.Tls_error -> "TLS handshake failed"
  | Llm_provider.Http_client.Timeout -> "network timeout"
  | Llm_provider.Http_client.Local_resource_exhaustion ->
    "local network resources exhausted"
  | Llm_provider.Http_client.End_of_file -> "connection closed"
  | Llm_provider.Http_client.Unknown -> "network error"
;;

let network_error_kind_user_action = function
  | Llm_provider.Http_client.Dns_failure ->
    "Check network/DNS or select another runtime."
  | Llm_provider.Http_client.Connection_refused ->
    "Check that the runtime endpoint is running or select another runtime."
  | Llm_provider.Http_client.Tls_error ->
    "Check the provider TLS endpoint or select another runtime."
  | Llm_provider.Http_client.Timeout ->
    "Check provider health or select another runtime."
  | Llm_provider.Http_client.Local_resource_exhaustion ->
    "Reduce concurrent requests or select another runtime."
  | Llm_provider.Http_client.End_of_file
  | Llm_provider.Http_client.Unknown ->
    "Check provider health or select another runtime."
;;

let runtime_provider_label provider =
  match Option.map String.trim provider with
  | Some provider when provider <> "" -> Printf.sprintf "Runtime provider '%s'" provider
  | _ -> "Runtime provider"
;;

let detail_suffix detail =
  match String.trim detail with
  | "" -> ""
  | detail -> " Detail: " ^ detail
;;

let provider_network_user_message ?provider ~kind ~detail () =
  Printf.sprintf
    "%s unavailable: %s. %s%s"
    (runtime_provider_label provider)
    (network_error_kind_user_label kind)
    (network_error_kind_user_action kind)
    (detail_suffix detail)
;;

let structured_internal_error_user_message err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some internal_error -> (
    match Keeper_internal_error.summary_of_masc_internal_error internal_error with
    | Some summary -> summary
    | None -> Agent_sdk.Error.to_string err)
  | None -> Agent_sdk.Error.to_string err
;;

let user_message_of_sdk_error = function
  | Agent_sdk.Error.Api (Agent_sdk.Retry.NetworkError { message; kind }) ->
    provider_network_user_message ~kind ~detail:message ()
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.NetworkError { provider; kind; detail; _ }) ->
    provider_network_user_message ~provider ~kind ~detail ()
  | err -> structured_internal_error_user_message err
;;

type sdk_termination_semantics =
  | Provider_wall_clock_timeout
  | Oas_agent_execution_timeout
  | Oas_turn_budget_exhausted
  | Oas_idle_budget_exhausted
  | Oas_exit_condition_reached
  | Oas_token_budget_exhausted
  | Oas_cost_budget_exhausted
  | Oas_cost_budget_unenforceable
  | Oas_guardrail_violation
  | Oas_tripwire_violation
  | Oas_input_required
  | Sdk_error_failure

let sdk_termination_semantics = function
  | Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout { message })
    when Keeper_error_classify.is_structural_oas_timeout_message message ->
    Oas_agent_execution_timeout
  | Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout _) -> Provider_wall_clock_timeout
  | Agent_sdk.Error.Provider (Llm_provider.Error.Timeout _)
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.NetworkError { timeout_phase = Some _; _ }) ->
    Provider_wall_clock_timeout
  | Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)
  | Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _) ->
    Oas_agent_execution_timeout
  | Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded _) ->
    Oas_turn_budget_exhausted
  | Agent_sdk.Error.Agent (Agent_sdk.Error.IdleDetected _) ->
    Oas_idle_budget_exhausted
  | Agent_sdk.Error.Agent (Agent_sdk.Error.ExitConditionMet _) ->
    Oas_exit_condition_reached
  | Agent_sdk.Error.Agent (Agent_sdk.Error.GuardrailViolation _) ->
    Oas_guardrail_violation
  | Agent_sdk.Error.Agent (Agent_sdk.Error.TripwireViolation _) ->
    Oas_tripwire_violation
  | Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired _) -> Oas_input_required
  | Agent_sdk.Error.Agent (Agent_sdk.Error.UnrecognizedStopReason _) -> Sdk_error_failure
  | Agent_sdk.Error.Provider _ -> Sdk_error_failure
  | Agent_sdk.Error.Api _ -> Sdk_error_failure
  | Agent_sdk.Error.Mcp _ -> Sdk_error_failure
  | Agent_sdk.Error.Config _ -> Sdk_error_failure
  | Agent_sdk.Error.Serialization _ -> Sdk_error_failure
  | Agent_sdk.Error.Io _ -> Sdk_error_failure
  | Agent_sdk.Error.Orchestration _ -> Sdk_error_failure
  | Agent_sdk.Error.Internal _ -> Sdk_error_failure
;;

let sdk_termination_semantics_to_string = function
  | Provider_wall_clock_timeout -> "provider_wall_clock_timeout"
  | Oas_agent_execution_timeout -> "oas_agent_execution_timeout"
  | Oas_turn_budget_exhausted -> "oas_turn_budget_exhausted"
  | Oas_idle_budget_exhausted -> "oas_idle_budget_exhausted"
  | Oas_exit_condition_reached -> "oas_exit_condition_reached"
  | Oas_token_budget_exhausted -> "oas_token_budget_exhausted"
  | Oas_cost_budget_exhausted -> "oas_cost_budget_exhausted"
  | Oas_cost_budget_unenforceable -> "oas_cost_budget_unenforceable"
  | Oas_guardrail_violation -> "oas_guardrail_violation"
  | Oas_tripwire_violation -> "oas_tripwire_violation"
  | Oas_input_required -> "oas_input_required"
  | Sdk_error_failure -> "sdk_error_failure"
;;

(* Per-variant terminal_reason_code for Agent_sdk.Error.Api.
   Previously every API failure collapsed to "api_error", so 7 keepers
   stuck on different conditions (rate limit, overload, server fault,
   auth) all displayed the same dashboard chip and the broadcast
   payload could not differentiate them. Memory:
   no-collapse-richer-enum-at-sdk-boundary. *)
let api_error_terminal_reason_code (err : Agent_sdk.Error.api_error) : string =
  match err with
  | Agent_sdk.Retry.RateLimited _ -> "api_error_rate_limited"
  | Agent_sdk.Retry.Overloaded _ -> "api_error_overloaded"
  | Agent_sdk.Retry.ServerError { status; _ } ->
    Printf.sprintf "api_error_server:%d" status
  | Agent_sdk.Retry.AuthError _ -> "api_error_auth"
  | Agent_sdk.Retry.PaymentRequired _ -> "api_error_payment_required"
  | Agent_sdk.Retry.InvalidRequest _ -> "api_error_invalid_request"
  | Agent_sdk.Retry.NotFound _ -> "api_error_not_found"
  | Agent_sdk.Retry.ContextOverflow _ -> "api_error_context_overflow"
  (* SSOT: the two transient wire codes are owned by [Keeper_terminal_reason]
     so the consumer-side disposition classifier
     ([Keeper_terminal_reason.is_transient_provider_runtime_failure]) and this
     encoder cannot drift. The structural-OAS-timeout branch keeps its own
     distinct (non-transient) code. *)
  | Agent_sdk.Retry.NetworkError _ -> Keeper_terminal_reason.wire_api_error_network
  | Agent_sdk.Retry.Timeout { message }
    when Keeper_error_classify.is_structural_oas_timeout_message message ->
    "api_error_oas_agent_execution_timeout"
  | Agent_sdk.Retry.Timeout _ -> Keeper_terminal_reason.wire_api_error_timeout
;;

(* Per-variant terminal_reason_code for Agent_sdk.Error.Agent.
   Previously every Agent failure collapsed to "agent_error", mirroring
   the old Api behaviour. Memory: no-collapse-richer-enum-at-sdk-boundary. *)
let agent_error_terminal_reason_code = function
  | Agent_sdk.Error.MaxTurnsExceeded { turns; limit } ->
    (* SSOT prefix: [Keeper_execution_receipt.is_auto_recoverable_turn_budget_terminal]
       matches on it to route the disposition to [Reason_turn_budget_exhausted]. *)
    Printf.sprintf
      "%s:turns=%d,limit=%d"
      Keeper_execution_receipt.terminal_prefix_max_turns_exceeded
      turns
      limit
  | Agent_sdk.Error.AgentExecutionTimeout
      { elapsed_sec; timeout_sec; turn_count; max_turns } ->
    Printf.sprintf
      "%s:elapsed_sec=%.1f,timeout_sec=%.1f,turn_count=%d,max_turns=%d"
      Keeper_execution_receipt.terminal_prefix_execution_timeout
      elapsed_sec
      timeout_sec
      turn_count
      max_turns
  | Agent_sdk.Error.AgentExecutionIdleTimeout
      { idle_sec; idle_timeout_sec; turn_count; max_turns } ->
    Printf.sprintf
      "%s:idle_sec=%.1f,idle_timeout_sec=%.1f,turn_count=%d,max_turns=%d"
      Keeper_execution_receipt.terminal_prefix_idle_timeout
      idle_sec
      idle_timeout_sec
      turn_count
      max_turns
  | Agent_sdk.Error.ExitConditionMet { turn } ->
    Printf.sprintf "agent_error_exit_condition_met:turn=%d" turn
  | Agent_sdk.Error.UnrecognizedStopReason { reason } ->
    Printf.sprintf "agent_error_unrecognized_stop_reason:%s" reason
  | Agent_sdk.Error.IdleDetected { consecutive_idle_turns } ->
    Printf.sprintf
      "agent_error_idle_detected:consecutive_idle_turns=%d"
      consecutive_idle_turns
  | Agent_sdk.Error.GuardrailViolation { validator; reason = _ } ->
    Printf.sprintf "agent_error_guardrail_violation:validator=%s" validator
  | Agent_sdk.Error.TripwireViolation { tripwire; reason = _ } ->
    Printf.sprintf "agent_error_tripwire_violation:tripwire=%s" tripwire
  | Agent_sdk.Error.InputRequired { request_id; question = _; _ } ->
    Printf.sprintf "agent_error_input_required:request_id=%s" request_id
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

let provider_timeout_suffix = function
  | None -> ""
  | Some phase ->
    ":" ^ Llm_provider.Http_client.timeout_phase_to_label phase
;;

let provider_error_terminal_reason_code = function
  | Llm_provider.Error.MissingApiKey _ -> "provider_error_missing_api_key"
  | Llm_provider.Error.InvalidConfig { field; _ } ->
    Printf.sprintf "provider_error_invalid_config:%s" field
  | Llm_provider.Error.ParseError _ -> "provider_error_parse"
  | Llm_provider.Error.UnknownVariant { type_name; _ } ->
    Printf.sprintf "provider_error_unknown_variant:%s" type_name
  | Llm_provider.Error.ProviderUnavailable _ -> "provider_error_unavailable"
  | Llm_provider.Error.RateLimit _ -> "provider_error_rate_limited"
  | Llm_provider.Error.HardQuota _ -> "provider_error_hard_quota"
  | Llm_provider.Error.CapacityExhausted { scope; _ } ->
    Printf.sprintf
      "provider_error_capacity_backpressure:%s"
      (Llm_provider.Error.capacity_scope_to_string scope)
  | Llm_provider.Error.AuthError _ -> "provider_error_auth"
  | Llm_provider.Error.ServerError { code; _ } ->
    Printf.sprintf "provider_error_server:%d" code
  | Llm_provider.Error.NetworkError { kind; timeout_phase; _ } ->
    Printf.sprintf
      "provider_error_network:%s%s"
      (network_error_kind_to_wire kind)
      (provider_timeout_suffix timeout_phase)
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    "provider_error_timeout" ^ provider_timeout_suffix timeout_phase
  | Llm_provider.Error.InvalidRequest _ -> "provider_error_invalid_request"
  | Llm_provider.Error.NotFound _ -> "provider_error_not_found"
  | Llm_provider.Error.ProviderTerminal { reason; _ } ->
    Printf.sprintf "provider_error_terminal:%s" reason
;;

let terminal_reason_code_of_sdk_error = function
  | Agent_sdk.Error.Agent err -> agent_error_terminal_reason_code err
  | Agent_sdk.Error.Api err -> api_error_terminal_reason_code err
  | Agent_sdk.Error.Provider err -> provider_error_terminal_reason_code err
  | Agent_sdk.Error.Mcp _ -> "mcp_error"
  | Agent_sdk.Error.Config _ -> "config_error"
  | Agent_sdk.Error.Serialization _ -> "serialization_error"
  | Agent_sdk.Error.Io _ -> "io_error"
  | Agent_sdk.Error.Orchestration _ -> "orchestration_error"
  | Agent_sdk.Error.Internal msg -> (
    match Keeper_internal_error.classify_masc_internal_error_of_string msg with
    | Some err -> Keeper_internal_error.kind_of_masc_internal_error err
    | None -> "internal_error")
;;

(* RFC-0042 PR-2.5: typed bridge for SDK errors. The wire format is the
   existing parametrised string (kept by [terminal_reason_code_of_sdk_error]
   above) wrapped in [Keeper_turn_terminal_code.Sdk_error]. PR-3 swaps
   [Keeper_turn_terminal.t.code] from [string] to [Keeper_turn_terminal_code.t]
   and uses these typed accessors at every emit site. RFC §5.2 defers the
   sub-sum split (per-variant constructors for [MaxTurnsExceeded] etc.) to
   a follow-up RFC. *)
let terminal_reason_code_of_sdk_error_typed err =
  Keeper_turn_terminal_code.of_sdk_error_wire (terminal_reason_code_of_sdk_error err)
;;

let api_error_terminal_reason_code_typed err =
  Keeper_turn_terminal_code.of_sdk_error_wire (api_error_terminal_reason_code err)
;;

let receipt_outcome_kind_of_sdk_error err =
  match sdk_termination_semantics err with
  | Provider_wall_clock_timeout
  | Oas_agent_execution_timeout
  | Oas_turn_budget_exhausted
  | Oas_idle_budget_exhausted
  | Oas_exit_condition_reached -> `Cancelled
  | Oas_input_required -> `Cancelled
  | Oas_token_budget_exhausted
  | Oas_cost_budget_exhausted
  | Oas_cost_budget_unenforceable
  | Oas_guardrail_violation
  | Oas_tripwire_violation
  | Sdk_error_failure -> `Error
;;

let checkpoint_persistence_error ~keeper_name ~detail =
  Agent_sdk.Error.Internal
    (Printf.sprintf
       "keeper_checkpoint_persist_failed: keeper=%s detail=%s"
       keeper_name
       detail)
;;

let runtime_outcome_of_observation
    : _ -> Keeper_execution_receipt.runtime_outcome = function
  | Some (obs : Runtime_observation.runtime_observation) when obs.fallback_applied ->
    Keeper_execution_receipt.Runtime_passed_to_next_model
  | Some obs
    when List.exists
           (fun (attempt : Runtime_observation.runtime_attempt) ->
              Option.is_some attempt.error)
           obs.attempts ->
    Keeper_execution_receipt.Runtime_failed
  | Some _ -> Keeper_execution_receipt.Runtime_completed
  | None -> Keeper_execution_receipt.Runtime_not_observed
;;
