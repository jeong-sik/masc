(** Error translation helpers for keeper Agent.run orchestration. *)

(** Coarse categorisation of [Agent_sdk.Error.sdk_error] (for dashboards). *)
val sdk_error_kind : Agent_sdk.Error.sdk_error -> string

(** Typed receipt error-kind counterpart of {!sdk_error_kind}. *)
val sdk_error_kind_for_receipt
  :  Agent_sdk.Error.sdk_error
  -> Keeper_execution_receipt.error_kind

(** User-facing SDK error message for keeper chat/tool surfaces.
    Keeps low-level SDK prefixes out of persisted keeper replies while
    telemetry and terminal reason codes continue to use structured errors. *)
val user_message_of_sdk_error : Agent_sdk.Error.sdk_error -> string

(** Layer-aware termination semantics for SDK errors crossing the OAS ->
    keeper boundary.

    DD-015: adjacent runtimes use "turn" and "timeout" at different
    layers. This contract preserves OAS observations without granting them
    Keeper pause, retry, or blocker authority. *)
type sdk_termination_semantics =
  | Provider_wall_clock_timeout
  | Oas_guardrail_violation
  | Oas_tripwire_violation
  | Oas_input_required
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

(** Receipt outcome for terminal SDK values. OAS turn-limit and execution-time
    observations remain successful even if they reach this defensive bridge;
    they are neither cancellation nor lifecycle-failure authority. *)
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
