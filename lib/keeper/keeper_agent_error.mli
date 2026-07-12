(** Error translation helpers for keeper Agent.run orchestration. *)

(** Coarse categorisation of [Agent_sdk.Error.sdk_error] (for dashboards). *)
val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

(** Typed receipt error-kind counterpart of {!sdk_error_kind}. *)
val sdk_error_kind_for_receipt
  :  Agent_sdk.Error.sdk_error
  -> Keeper_execution_receipt.error_kind

(** Which side of the OAS boundary [err] originates from, for typed
    downstream classification (e.g. keeper chat Row_kind). [Transport_layer]
    is the wire-level Api/Provider failure surface reaching the LLM
    backend; every other constructor is the agent's own execution, config,
    or orchestration outcome — not a transport-layer failure. *)
type failure_origin =
  | Transport_layer
  | Agent_layer

val failure_origin_of_sdk_error : Agent_sdk.Error.sdk_error -> failure_origin

(** User-facing SDK error message for keeper chat/tool surfaces.
    Keeps low-level SDK prefixes out of persisted keeper replies while
    telemetry and terminal reason codes continue to use structured errors. *)
val user_message_of_sdk_error : Agent_sdk.Error.sdk_error -> string

(** Layer-aware termination semantics for SDK errors crossing the OAS ->
    keeper boundary.

    DD-015: adjacent runtimes use "turn" and "timeout" at different
    layers.  This contract keeps OAS turn-budget stops distinct from
    keeper wall-clock/provider timeouts before they collapse to receipt
    outcomes. *)
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
  | Oas_tool_failure_recovery_failed
  | Oas_tool_failure_recovery_deferred
  | Sdk_error_failure

val sdk_termination_semantics
  :  Agent_sdk.Error.sdk_error
  -> sdk_termination_semantics

val sdk_termination_semantics_to_string : sdk_termination_semantics -> string

(** RFC-0042 PR-2.5: typed bridge variants of the wire accessors.
    Wrap the existing parametrised wire string in
    [Keeper_turn_terminal_code.Sdk_error]. PR-3 swaps
    [Keeper_turn_terminal.t.code] from [string] to
    [Keeper_turn_terminal_code.t] and uses these accessors at every
    emit site. RFC §5.2 explicitly defers per-variant constructors
    (~25-variant explosion); a follow-up RFC will split [Sdk_error] once
    production traces narrow the actual sub-kind set.

    Byte invariant guarded by [test_keeper_sdk_error_typed_bridge].

    @since 0.193.1 *)
val terminal_reason_code_of_sdk_error : Agent_sdk.Error.sdk_error -> string

val terminal_reason_code_of_sdk_error_typed
  :  Agent_sdk.Error.sdk_error
  -> Keeper_turn_terminal_code.t

(** Typed counterpart of [api_error_terminal_reason_code]. *)
val api_error_terminal_reason_code_typed
  :  Agent_sdk.Error.api_error
  -> Keeper_turn_terminal_code.t

(** Receipt outcome for terminal SDK errors.  Provider/time-budget stop
    semantics retain their existing [`Cancelled] mapping.  Behavioral
    [IdleDetected] is an ordinary failed receipt: it is not evidence of a
    user or supervisor cancellation. *)
val receipt_outcome_kind_of_sdk_error
  :  Agent_sdk.Error.sdk_error
  -> Keeper_execution_receipt.outcome_kind

(** Structured internal error for post-turn checkpoint persistence
    failures.  Used to prevent an otherwise successful keeper turn from
    returning [Ok] when the replay checkpoint is not durable. *)
val checkpoint_persistence_error
  :  keeper_name:string
  -> detail:string
  -> Agent_sdk.Error.sdk_error

(** Map an optional runtime observation to a typed runtime outcome
    ([Runtime_passed_to_next_model] / [Runtime_completed] /
    [Runtime_failed] / [Runtime_not_observed]). *)
val runtime_outcome_of_observation
  :  Runtime_observation.runtime_observation option
  -> Keeper_execution_receipt.runtime_outcome
