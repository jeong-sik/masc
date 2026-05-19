(** Keeper_failure_policy -- pure keeper failure ownership matrix.

    This module answers one question before any supervisor side effect:
    "does this failure belong to a tool invocation, provider call, turn,
    keeper liveness, or the fleet?"  It deliberately keeps provider and
    OAS timeout evidence separate from keeper lifecycle decisions so a
    streaming/thinking timeout cannot be treated as a dead keeper. *)

type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown

val stream_idle_state_to_label : stream_idle_state -> string
val stream_idle_state_of_label : string -> stream_idle_state option
val stream_idle_state_is_activity : stream_idle_state -> bool

type timeout_phase =
  | Admission
  | Queue
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_idle_state
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Unknown_timeout

val timeout_phase_to_label : timeout_phase -> string
val timeout_phase_of_label : string -> timeout_phase option
val timeout_phase_is_streaming_activity : timeout_phase -> bool

type liveness_evidence =
  | Recent_heartbeat
  | In_turn_progress
  | Watchdog_stale
  | No_recent_heartbeat
  | Unknown_liveness

type failure =
  | Workflow_rejection of { rule_id : string option }
  | Provider_timeout of
      { phase : timeout_phase option
      ; liveness : liveness_evidence
      }
  | Oas_timeout_budget of
      { phase : timeout_phase option
      ; strikes : int option
      ; liveness : liveness_evidence
      }
  | Transient_provider_failure
  | Cascade_exhausted of { retryable : bool }
  | Required_tool_contract_violation
  | Fatal_environment of { detail : string option }
  | Stale_turn of { progress_seen : bool }
  | Stale_termination_storm of { count : int }
  | Ambiguous_partial_commit

type failure_scope =
  | Invocation_scope
  | Provider_scope
  | Turn_scope
  | Keeper_liveness_scope
  | Fleet_scope

type lifecycle_effect =
  | Keep_running
  | Soft_fail_turn
  | Pause_current_work
  | Force_release_turn
  | Pause_keeper
  | Restart_keeper

type circuit_effect =
  | Skip_circuit
  | Count_for_circuit
  | Provider_cooldown
  | Operator_breaker

type operator_action =
  | No_operator_action
  | Fix_invocation
  | Inspect_provider_stream
  | Inspect_timeout_budget
  | Reroute_or_tune_provider
  | Inspect_required_tool_contract
  | Reconcile_partial_commit
  | Inspect_keeper_liveness
  | Fix_runtime_environment

type decision =
  { failure_scope : failure_scope
  ; lifecycle_effect : lifecycle_effect
  ; circuit_effect : circuit_effect
  ; operator_action : operator_action
  ; keeper_death_allowed : bool
  ; reason : string
  }

val decide : failure -> decision
val should_kill_keeper : decision -> bool

val failure_scope_to_label : failure_scope -> string
val lifecycle_effect_to_label : lifecycle_effect -> string
val circuit_effect_to_label : circuit_effect -> string
val operator_action_to_label : operator_action -> string
