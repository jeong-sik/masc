(** Error translation helpers for keeper Agent.run orchestration. *)

(* One SSOT for the sentence a failed request shows a person: the typed value
   renders itself ([Keeper_request_failure.summary]). This used to be four
   renderers here, and the row they wrote was the only place the cause
   survived; RFC-0454 D2 moved the decision into the value, so this is the
   projection plus its summary and nothing else. *)
let user_message_of_core_error err =
  Keeper_request_failure.summary (Keeper_request_failure.of_core_error err)
;;

type core_termination_semantics =
  | Provider_wall_clock_timeout
  | Agent_core_guardrail_violation
  | Agent_core_tripwire_violation
  | Agent_core_input_required
  | Preempted_by_person
  | Core_error_failure

let core_termination_semantics err =
  match err with
  | Agent_core.Error.Api (Agent_core.Retry.Timeout _) -> Provider_wall_clock_timeout
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout _)
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError { timeout_phase = Some _; _ }) ->
    Provider_wall_clock_timeout
  | Agent_core.Error.Agent (Agent_core.Error.GuardrailViolation _) ->
    Agent_core_guardrail_violation
  | Agent_core.Error.Agent (Agent_core.Error.TripwireViolation _) ->
    Agent_core_tripwire_violation
  | Agent_core.Error.Agent (Agent_core.Error.InputRequired _) -> Agent_core_input_required
  | Agent_core.Error.Agent (Agent_core.Error.UnrecognizedStopReason _)
  | Agent_core.Error.Agent (Agent_core.Error.ToolRoundLimitExceeded _)
  | Agent_core.Error.Agent (Agent_core.Error.HookExecutionFailed _)
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolEffectFailed _)
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolDurabilityFailed _) ->
    Core_error_failure
  | Agent_core.Error.Provider _ -> Core_error_failure
  | Agent_core.Error.Api _ -> Core_error_failure
  | Agent_core.Error.Mcp _ -> Core_error_failure
  | Agent_core.Error.Config _ -> Core_error_failure
  | Agent_core.Error.Serialization _ -> Core_error_failure
  | Agent_core.Error.Io _ -> Core_error_failure
  | Agent_core.Error.Orchestration _ -> Core_error_failure
  | Agent_core.Error.Internal_carried { message = _; _ }
    when Keeper_internal_error.is_preempted_before_first_token err ->
    (* #38094: the turn yielded to a queued person; nothing failed. *)
    Preempted_by_person
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> Core_error_failure
;;

let core_termination_semantics_to_string = function
  | Provider_wall_clock_timeout -> "provider_wall_clock_timeout"
  | Agent_core_guardrail_violation -> "agent_core_guardrail_violation"
  | Agent_core_tripwire_violation -> "agent_core_tripwire_violation"
  | Agent_core_input_required -> "agent_core_input_required"
  | Preempted_by_person -> "preempted_by_person"
  | Core_error_failure -> "core_error_failure"
;;

(* Per-variant terminal_reason_code for Agent_core.Error.Api.
   Previously every API failure collapsed to "api_error", so 7 keepers
   stuck on different conditions (rate limit, overload, server fault,
   auth) all displayed the same dashboard chip and the broadcast
   payload could not differentiate them. Memory:
   no-collapse-richer-enum-at-sdk-boundary. *)
let api_error_terminal_reason_code (err : Agent_core.Error.api_error) : string =
  match err with
  | Agent_core.Retry.RateLimited _ -> "api_error_rate_limited"
  | Agent_core.Retry.Overloaded _ -> "api_error_overloaded"
  | Agent_core.Retry.ServerError { status; _ } ->
    Printf.sprintf "api_error_server:%d" status
  | Agent_core.Retry.AuthError _ -> "api_error_auth"
  | Agent_core.Retry.AuthorizationError _ -> "api_error_authorization"
  | Agent_core.Retry.PaymentRequired _ -> "api_error_payment_required"
  | Agent_core.Retry.InvalidRequest _ -> "api_error_invalid_request"
  | Agent_core.Retry.NotFound _ -> "api_error_not_found"
  | Agent_core.Retry.ContextOverflow _ -> "api_error_context_overflow"
  | Agent_core.Retry.InputCapacity { reason; _ } ->
    (match reason with
     | Agent_core.Retry.Serving_constraint_rejected _ ->
       "api_error_input_capacity:serving_constraint_rejected"
     | Agent_core.Retry.Token_measurement_unavailable _ ->
       "api_error_input_capacity:measurement_unavailable")
  (* SSOT: the two transient wire codes are owned by [Keeper_terminal_reason]
     so the consumer-side disposition classifier
     ([Keeper_terminal_reason.is_transient_provider_runtime_failure]) and this
     encoder cannot drift. Agent execution observations are represented by the
     typed Agent error constructors above this API layer. *)
  | Agent_core.Retry.NetworkError _ -> Keeper_terminal_reason.wire_api_error_network
  | Agent_core.Retry.Timeout _ -> Keeper_terminal_reason.wire_api_error_timeout
;;

(* Per-variant terminal_reason_code for Agent_core.Error.Agent.
   Previously every Agent failure collapsed to "agent_error", mirroring
   the old Api behaviour. Memory: no-collapse-richer-enum-at-sdk-boundary. *)
let terminal_effect_disposition_to_wire effect_disposition =
  match Agent_core.Error.terminal_effect_disposition effect_disposition with
  | Agent_core.Tool_contract.Proven_pre_effect -> "proven_pre_effect"
  | Agent_core.Tool_contract.Proven_post_effect -> "proven_post_effect"
  | Agent_core.Tool_contract.Effect_outcome_unknown -> "effect_outcome_unknown"
;;

let agent_error_terminal_reason_code = function
  | Agent_core.Error.UnrecognizedStopReason { reason } ->
    Printf.sprintf "agent_error_unrecognized_stop_reason:%s" reason
  | Agent_core.Error.ToolRoundLimitExceeded { rounds; limit } ->
    Printf.sprintf "agent_error_tool_round_limit_exceeded:rounds=%d,limit=%d" rounds limit
  | Agent_core.Error.HookExecutionFailed { hook_name; stage; _ } ->
    Printf.sprintf
      "agent_error_hook_execution_failed:hook=%s,stage=%s"
      hook_name
      stage
  | Agent_core.Error.TerminalToolEffectFailed
      { tool_use_id; effect_disposition; detail = _ } ->
    Printf.sprintf
      (* One spelling for one concept. The reader matches this against
         [Keeper_internal_error.all_wire_kinds], so naming the kind here and
         reading it there must go through the same constant -- otherwise the
         reason decodes as [Unknown] and the receipt lands unmapped. *)
      "%s:tool_use_id=%s,effect_disposition=%s"
      Keeper_internal_error.terminal_effect_failed_kind
      tool_use_id
      (terminal_effect_disposition_to_wire effect_disposition)
  | Agent_core.Error.TerminalToolDurabilityFailed
      { invocation; effect_disposition; detail = _ } ->
    Printf.sprintf
      "agent_error_terminal_tool_durability_failed:tool_use_id=%s,effect_disposition=%s"
      (Agent_core.Tool_contract.Invocation.tool_use_id invocation)
      (terminal_effect_disposition_to_wire effect_disposition)
  | Agent_core.Error.GuardrailViolation { validator; reason = _ } ->
    Printf.sprintf "agent_error_guardrail_violation:validator=%s" validator
  | Agent_core.Error.TripwireViolation { tripwire; reason = _ } ->
    Printf.sprintf "agent_error_tripwire_violation:tripwire=%s" tripwire
  | Agent_core.Error.InputRequired { request_id; question = _; _ } ->
    Printf.sprintf "agent_error_input_required:request_id=%s" request_id
;;

let network_error_kind_to_wire = Keeper_internal_error.network_error_kind_to_string

let provider_timeout_suffix = function
  | None -> ""
  | Some phase ->
    ":" ^ Llm_provider.Http_client.timeout_phase_to_label phase
;;

let provider_error_terminal_reason_code = function
  | Llm_provider.Error.MissingApiKey _ -> "provider_error_missing_api_key"
  | Llm_provider.Error.InvalidConfig { field; _ } ->
    Keeper_terminal_reason.wire_provider_error_invalid_config_prefix ^ field
  | Llm_provider.Error.ParseError _ -> "provider_error_parse"
  | Llm_provider.Error.ProviderWireError { format; kind; _ } ->
    Printf.sprintf
      "provider_error_wire:%s:%s"
      (Llm_provider.Http_client.provider_wire_format_to_string format)
      (Llm_provider.Http_client.provider_wire_error_kind_to_string kind)
  | Llm_provider.Error.ProviderReportedError { error_type = Some error_type; _ } ->
    Printf.sprintf "provider_error_reported:%s" error_type
  | Llm_provider.Error.ProviderReportedError { error_type = None; _ } ->
    "provider_error_reported"
  | Llm_provider.Error.UnknownVariant { type_name; _ } ->
    Printf.sprintf "provider_error_unknown_variant:%s" type_name
  | Llm_provider.Error.ProviderUnavailable _ -> "provider_error_unavailable"
  | Llm_provider.Error.EmptyCompletion _ -> "provider_error_empty_completion"
  | Llm_provider.Error.RepeatingGeneration { shape; _ } ->
    Printf.sprintf
      "provider_error_repeating_generation:%s"
      (Llm_provider.Types.repeating_shape_to_string shape)
  | Llm_provider.Error.RateLimit _ -> "provider_error_rate_limited"
  | Llm_provider.Error.HardQuota _ -> "provider_error_hard_quota"
  | Llm_provider.Error.CapacityExhausted { scope; _ } ->
    Printf.sprintf
      "provider_error_capacity_backpressure:%s"
      (Llm_provider.Error.capacity_scope_to_string scope)
  | Llm_provider.Error.AuthError _ -> Keeper_terminal_reason.wire_provider_error_auth
  | Llm_provider.Error.AuthorizationError _ ->
    Keeper_terminal_reason.wire_provider_error_authorization
  | Llm_provider.Error.ServerError { code; _ } ->
    Printf.sprintf "provider_error_server:%d" code
  | Llm_provider.Error.NetworkError { kind; timeout_phase; _ } ->
    Printf.sprintf
      "provider_error_network:%s%s"
      (network_error_kind_to_wire kind)
      (provider_timeout_suffix timeout_phase)
  | Llm_provider.Error.Timeout { timeout_phase; _ } ->
    Keeper_terminal_reason.wire_provider_error_timeout
    ^ provider_timeout_suffix timeout_phase
  | Llm_provider.Error.InvalidRequest _ -> "provider_error_invalid_request"
  | Llm_provider.Error.NotFound _ -> "provider_error_not_found"
  | Llm_provider.Error.ProviderTerminal { reason; _ } ->
    Printf.sprintf "provider_error_terminal:%s" reason
;;

let terminal_reason_code_of_core_error = function
  | Agent_core.Error.Agent err -> agent_error_terminal_reason_code err
  | Agent_core.Error.Api err -> api_error_terminal_reason_code err
  | Agent_core.Error.Provider err -> provider_error_terminal_reason_code err
  | Agent_core.Error.Mcp _ -> "mcp_error"
  | Agent_core.Error.Config _ -> "config_error"
  | Agent_core.Error.Serialization _ -> "serialization_error"
  | Agent_core.Error.Io _ -> "io_error"
  | Agent_core.Error.Orchestration _ -> "orchestration_error"
  | (Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried _) as err -> (
    (* Typed carrier first; the string parse survives inside
       classify_masc_internal_error for pre-carrier producers
       (RFC-0371 B12). *)
    match Keeper_internal_error.classify_masc_internal_error err with
    | Some err -> Keeper_internal_error.kind_of_masc_internal_error err
    | None -> "internal_error")
;;

(* RFC-0042 PR-2.5: typed bridge for agent-core errors. The wire format is the
   existing parametrised string (kept by [terminal_reason_code_of_core_error]
   above) wrapped in [Keeper_turn_terminal_code.Agent_core_error]. PR-3 swaps
   [Keeper_turn_terminal.t.code] from [string] to [Keeper_turn_terminal_code.t]
   and uses these typed accessors at every emit site. RFC §5.2 defers the
   sub-sum split (per-variant constructors for Agent errors) to
   a follow-up RFC. *)
(* The typed timeout observation is derived here — the one site that still
   holds the original error — and rides the terminal code next to the
   verbatim wire (RFC-0371 §6.1(3)). Consumers stop re-parsing
   "provider_error_timeout:*" out of the wire for live values; the string
   classifier remains only for wire rehydrated from persistence. *)
let agent_core_timeout_observation :
      Agent_core.Error.t -> Keeper_turn_terminal_code.agent_core_timeout option
  = function
  | Agent_core.Error.Api (Timeout { phase; _ }) ->
    Some { Keeper_turn_terminal_code.source = Agent_core_api; phase }
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout { timeout_phase; _ }) ->
    Some
      { Keeper_turn_terminal_code.source = Agent_core_provider; phase = timeout_phase }
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError { timeout_phase = Some phase; _ }) ->
    Some { Keeper_turn_terminal_code.source = Agent_core_provider; phase = Some phase }
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError
         { kind = Llm_provider.Http_client.Timeout; timeout_phase = None; _ }) ->
    Some { Keeper_turn_terminal_code.source = Agent_core_provider; phase = None }
  | _ -> None
;;

let terminal_reason_code_of_core_error_typed err =
  Keeper_turn_terminal_code.of_core_error
    ~wire:(terminal_reason_code_of_core_error err)
    ~timeout:(agent_core_timeout_observation err)
;;

let api_error_terminal_reason_code_typed err =
  terminal_reason_code_of_core_error_typed (Agent_core.Error.Api err)
;;

let receipt_outcome_kind_of_core_error err =
  match core_termination_semantics err with
  | Provider_wall_clock_timeout -> `Cancelled
  | Agent_core_input_required -> `Cancelled
  | Preempted_by_person -> `Cancelled
  | Agent_core_guardrail_violation
  | Agent_core_tripwire_violation
  | Core_error_failure -> `Error
;;

let checkpoint_persistence_error ~keeper_name ~detail =
  Agent_core.Error.Internal
    (Printf.sprintf
       "keeper_checkpoint_persist_failed: keeper=%s detail=%s"
       keeper_name
       detail)
;;

let runtime_outcome_of_observation
    ~(lane_failover_applied : bool)
    : Runtime_observation.runtime_observation option ->
      Keeper_execution_receipt.runtime_outcome = function
  | Some _ when lane_failover_applied ->
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
