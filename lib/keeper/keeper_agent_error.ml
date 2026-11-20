(** Error translation helpers for keeper Agent.run orchestration. *)

(* One SSOT for the sentence a failed request shows a person: the typed value
   renders itself ([Keeper_request_failure.summary]), so this is the
   projection plus its summary and nothing else. *)
let user_message_of_core_error err =
  Keeper_request_failure.summary (Keeper_request_failure.of_core_error err)
;;

type core_termination_semantics =
  | Provider_wall_clock_timeout
  | Agent_core_input_required
  | Core_error_failure

let core_termination_semantics err =
  match err with
  | Agent_core.Error.Api (Agent_core.Retry.Timeout _) -> Provider_wall_clock_timeout
  | Agent_core.Error.Provider (Llm_provider.Error.Timeout _)
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError { timeout_phase = Some _; _ }) ->
    Provider_wall_clock_timeout
  | Agent_core.Error.Agent (Agent_core.Error.InputRequired _) -> Agent_core_input_required
  | Agent_core.Error.Agent (Agent_core.Error.UnrecognizedStopReason _)
  | Agent_core.Error.Agent (Agent_core.Error.ToolRoundLimitExceeded _)
  | Agent_core.Error.Agent (Agent_core.Error.HookExecutionFailed _)
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolEffectFailed _)
  | Agent_core.Error.Agent (Agent_core.Error.TerminalToolDurabilityFailed _) ->
    Core_error_failure
  | Agent_core.Error.Provider
      ( Llm_provider.Error.InvalidConfig _
      | Llm_provider.Error.ParseError _
      | Llm_provider.Error.ProviderWireError _
      | Llm_provider.Error.ProviderReportedError _
      | Llm_provider.Error.UnknownVariant _
      | Llm_provider.Error.ProviderUnavailable _
      | Llm_provider.Error.EmptyCompletion _
      | Llm_provider.Error.RateLimit _
      | Llm_provider.Error.HardQuota _
      | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.AuthError _
      | Llm_provider.Error.AuthorizationError _
      | Llm_provider.Error.ServerError _
      | Llm_provider.Error.NetworkError _
      | Llm_provider.Error.Connect_failed _
      | Llm_provider.Error.InvalidRequest _
      | Llm_provider.Error.NotFound _
      | Llm_provider.Error.ProviderTerminal _ ) -> Core_error_failure
  | Agent_core.Error.Api (Agent_core.Retry.RateLimited _)
  | Agent_core.Error.Api (Agent_core.Retry.Overloaded _)
  | Agent_core.Error.Api (Agent_core.Retry.ServerError _)
  | Agent_core.Error.Api (Agent_core.Retry.AuthError _)
  | Agent_core.Error.Api (Agent_core.Retry.AuthorizationError _)
  | Agent_core.Error.Api (Agent_core.Retry.PaymentRequired _)
  | Agent_core.Error.Api (Agent_core.Retry.InvalidRequest _)
  | Agent_core.Error.Api (Agent_core.Retry.NotFound _)
  | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow _)
  | Agent_core.Error.Api (Agent_core.Retry.InputCapacity _)
  | Agent_core.Error.Api (Agent_core.Retry.NetworkError _)
  | Agent_core.Error.Api (Agent_core.Retry.Connect_failed _) -> Core_error_failure
  | Agent_core.Error.Mcp _ -> Core_error_failure
  | Agent_core.Error.Config _ -> Core_error_failure
  | Agent_core.Error.Serialization _ -> Core_error_failure
  | Agent_core.Error.Io _ -> Core_error_failure
  | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _ -> Core_error_failure
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> Core_error_failure
;;

let core_termination_semantics_to_string = function
  | Provider_wall_clock_timeout -> "provider_wall_clock_timeout"
  | Agent_core_input_required -> "agent_core_input_required"
  | Core_error_failure -> "core_error_failure"
;;

(* Typed bridge for agent-core errors. The wire format is the parametrised
   string [Keeper_terminal_reason.code_of_core_error] writes, wrapped in
   [Keeper_turn_terminal_code.Agent_core_error]. *)
(* The typed timeout observation is derived here — the one site that still
   holds the original error — and rides the terminal code next to the
   verbatim wire. Consumers stop re-parsing
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
         { kind = Llm_provider.Http_client.Timeout; timeout_phase = None; _ })
  | Agent_core.Error.Provider
      (Llm_provider.Error.Connect_failed { kind = Llm_provider.Http_client.Timeout; _ }) ->
    Some { Keeper_turn_terminal_code.source = Agent_core_provider; phase = None }
  | Agent_core.Error.Provider
      (Llm_provider.Error.NetworkError
         { kind =
             ( Llm_provider.Http_client.Connection_refused
             | Llm_provider.Http_client.Dns_failure
             | Llm_provider.Http_client.Unreachable
             | Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Local_resource_exhaustion
             | Llm_provider.Http_client.Connection_reset
             | Llm_provider.Http_client.End_of_file
             | Llm_provider.Http_client.Unknown )
         ; timeout_phase = None
         ; _
         })
  | Agent_core.Error.Provider
      (Llm_provider.Error.Connect_failed
         { kind =
             ( Llm_provider.Http_client.Connection_refused
             | Llm_provider.Http_client.Dns_failure
             | Llm_provider.Http_client.Unreachable
             | Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Local_resource_exhaustion
             | Llm_provider.Http_client.Connection_reset
             | Llm_provider.Http_client.End_of_file
             | Llm_provider.Http_client.Unknown )
         ; _
         })
  | Agent_core.Error.Provider
      ( Llm_provider.Error.InvalidConfig _
      | Llm_provider.Error.ParseError _
      | Llm_provider.Error.ProviderWireError _
      | Llm_provider.Error.ProviderReportedError _
      | Llm_provider.Error.UnknownVariant _
      | Llm_provider.Error.ProviderUnavailable _
      | Llm_provider.Error.EmptyCompletion _
      | Llm_provider.Error.RateLimit _
      | Llm_provider.Error.HardQuota _
      | Llm_provider.Error.CapacityExhausted _
      | Llm_provider.Error.AuthError _
      | Llm_provider.Error.AuthorizationError _
      | Llm_provider.Error.ServerError _
      | Llm_provider.Error.InvalidRequest _
      | Llm_provider.Error.NotFound _
      | Llm_provider.Error.ProviderTerminal _ )
  | Agent_core.Error.Api
      ( Llm_provider.Retry.RateLimited _
      | Llm_provider.Retry.Overloaded _
      | Llm_provider.Retry.ServerError _
      | Llm_provider.Retry.AuthError _
      | Llm_provider.Retry.AuthorizationError _
      | Llm_provider.Retry.PaymentRequired _
      | Llm_provider.Retry.InvalidRequest _
      | Llm_provider.Retry.NotFound _
      | Llm_provider.Retry.ContextOverflow _
      | Llm_provider.Retry.InputCapacity _
      | Llm_provider.Retry.NetworkError _
      | Llm_provider.Retry.Connect_failed _ )
  | Agent_core.Error.Agent _ | Agent_core.Error.Mcp _ | Agent_core.Error.Config _
  | Agent_core.Error.Serialization _ | Agent_core.Error.Io _ | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried _ -> None
;;

let terminal_reason_code_of_core_error_typed err =
  Keeper_turn_terminal_code.of_core_error
    ~wire:(Keeper_terminal_reason.code_of_core_error err)
    ~timeout:(agent_core_timeout_observation err)
;;

let api_error_terminal_reason_code_typed err =
  terminal_reason_code_of_core_error_typed (Agent_core.Error.Api err)
;;

let receipt_outcome_kind_of_core_error err =
  match core_termination_semantics err with
  | Provider_wall_clock_timeout -> `Cancelled
  | Agent_core_input_required -> `Cancelled
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
  | Some obs ->
    (match obs.execution_evidence with
     | Runtime_observation.Uncaptured_failure _ -> Keeper_execution_receipt.Runtime_failed
     | Runtime_observation.Captured_execution ->
       match obs.host_acceptance with
       | Some (Runtime_observation.Rejected _) -> Keeper_execution_receipt.Runtime_failed
       | None | Some Runtime_observation.Accepted ->
         if List.exists (fun (attempt : Runtime_observation.runtime_attempt) ->
           Option.is_some attempt.error) obs.attempts
         then Keeper_execution_receipt.Runtime_failed
         else Keeper_execution_receipt.Runtime_completed)
  | None -> Keeper_execution_receipt.Runtime_not_observed
;;
