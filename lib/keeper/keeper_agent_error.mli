(** Error translation helpers for keeper Agent.run orchestration. *)

(** User-facing agent-core error message for keeper chat/tool surfaces.
    Keeps low-level agent-core prefixes out of persisted keeper replies while
    telemetry and terminal reason codes continue to use structured errors. *)
val user_message_of_core_error : Agent_core.Error.t -> string

(** Layer-aware termination semantics for agent-core errors crossing the AGENT_CORE ->
    keeper boundary.

    DD-015: adjacent runtimes use "turn" and "timeout" at different
    layers. This contract preserves AGENT_CORE observations without granting them
    Keeper pause, retry, or blocker authority. *)
type core_termination_semantics =
  | Provider_wall_clock_timeout
  | Agent_core_guardrail_violation
  | Agent_core_tripwire_violation
  | Agent_core_input_required
  | Core_error_failure

val core_termination_semantics
  :  Agent_core.Error.t
  -> core_termination_semantics

val core_termination_semantics_to_string : core_termination_semantics -> string

(** Snake_case wire label for a provider network error kind
    ([Connection_refused] -> ["connection_refused"], [Dns_failure] ->
    ["dns_failure"], [Tls_error] -> ["tls_error"], [Timeout] ->
    ["timeout"], [Local_resource_exhaustion] ->
    ["local_resource_exhaustion"], [End_of_file] -> ["end_of_file"],
    [Unknown] -> ["unknown"]). *)
val network_error_kind_to_wire : Llm_provider.Http_client.network_error_kind -> string

(** Snake_case wire label for the disposition carried by a closed terminal
    tool effect: ["proven_pre_effect"], ["proven_post_effect"] or
    ["effect_outcome_unknown"]. *)
val terminal_effect_disposition_to_wire
  :  Agent_core.Error.closed_terminal_effect
  -> string

(** RFC-0042 PR-2.5: typed bridge variants of the wire accessors.
    Wrap the existing parametrised wire string in
    [Keeper_turn_terminal_code.Agent_core_error]. PR-3 swaps
    [Keeper_turn_terminal.t.code] from [string] to
    [Keeper_turn_terminal_code.t] and uses these accessors at every
    emit site. RFC §5.2 explicitly defers per-variant constructors
    (~25-variant explosion); a follow-up RFC will split [Agent_core_error] once
    production traces narrow the actual sub-kind set.

    Byte invariant guarded by [test_keeper_core_error_typed_bridge].

    @since 0.193.1 *)
val terminal_reason_code_of_core_error : Agent_core.Error.t -> string

val terminal_reason_code_of_core_error_typed
  :  Agent_core.Error.t
  -> Keeper_turn_terminal_code.t

(** Typed counterpart of [api_error_terminal_reason_code]. *)
val api_error_terminal_reason_code_typed
  :  Agent_core.Error.api_error
  -> Keeper_turn_terminal_code.t

(** Receipt outcome for terminal agent-core values. AGENT_CORE turn-limit and execution-time
    observations remain successful even if they reach this defensive bridge;
    they are neither cancellation nor lifecycle-failure authority. *)
val receipt_outcome_kind_of_core_error
  :  Agent_core.Error.t
  -> Keeper_execution_receipt.outcome_kind

(** Structured internal error for post-turn checkpoint persistence
    failures.  Used to prevent an otherwise successful keeper turn from
    returning [Ok] when the replay checkpoint is not durable. *)
val checkpoint_persistence_error
  :  keeper_name:string
  -> detail:string
  -> Agent_core.Error.t

(** Map an optional runtime observation to a typed runtime outcome
    ([Runtime_passed_to_next_model] / [Runtime_completed] /
    [Runtime_failed] / [Runtime_not_observed]).
    [lane_failover_applied] is the lane walk's truth (this turn settled on
    a candidate at a lane index > 0) — it decides
    [Runtime_passed_to_next_model], not any field on the observation
    itself. *)
val runtime_outcome_of_observation
  :  lane_failover_applied:bool
  -> Runtime_observation.runtime_observation option
  -> Keeper_execution_receipt.runtime_outcome
