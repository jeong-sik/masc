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

let stream_idle_state_to_label = function
  | Awaiting_first_event -> "awaiting_first_event"
  | Awaiting_first_delta -> "awaiting_first_delta"
  | Streaming_answer -> "streaming_answer"
  | Streaming_thinking -> "streaming_thinking"
  | Streaming_tool_call -> "streaming_tool_call"
  | Streaming_heartbeat -> "streaming_heartbeat"
  | Streaming_substrate -> "streaming_substrate"
  | Streaming_done -> "streaming_done"
  | Streaming_unknown -> "streaming_unknown"
;;

let stream_idle_state_of_label = function
  | "awaiting_first_event" -> Some Awaiting_first_event
  | "awaiting_first_delta" -> Some Awaiting_first_delta
  | "streaming_answer" -> Some Streaming_answer
  | "streaming_thinking" -> Some Streaming_thinking
  | "streaming_tool_call" -> Some Streaming_tool_call
  | "streaming_heartbeat" -> Some Streaming_heartbeat
  | "streaming_substrate" -> Some Streaming_substrate
  | "streaming_done" -> Some Streaming_done
  | "streaming_unknown" -> Some Streaming_unknown
  | _ -> None
;;

let stream_idle_state_is_activity = function
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate -> true
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_done
  | Streaming_unknown -> false
;;

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

let timeout_phase_to_label = function
  | Admission -> "admission"
  | Queue -> "queue"
  | First_token -> "first_token"
  | Http_operation -> "http_operation"
  | Non_streaming_body -> "non_streaming_body"
  | Stream_body -> "stream_body"
  | Stream_idle state -> "stream_idle:" ^ stream_idle_state_to_label state
  | Provider_step -> "provider_step"
  | Cli_stdout_idle -> "cli_stdout_idle"
  | Caller_budget -> "caller_budget"
  | Wall_clock -> "wall_clock"
  | Capacity_backpressure -> "capacity_backpressure"
  | Unknown_timeout -> "unknown_timeout"
;;

let timeout_phase_of_label label =
  let normalize label =
    label
    |> String.trim
    |> String.lowercase_ascii
    |> String.map (function
      | '-' | ' ' -> '_'
      | ch -> ch)
  in
  let label = normalize label in
  let stream_idle_prefix = "stream_idle:" in
  if String.starts_with ~prefix:stream_idle_prefix label
  then
    let prefix_len = String.length stream_idle_prefix in
    String.sub label prefix_len (String.length label - prefix_len)
    |> stream_idle_state_of_label
    |> Option.map (fun state -> Stream_idle state)
  else
    match label with
    | "admission" | "admission_timeout" -> Some Admission
    | "queue" | "provider_queue" | "admission_queue"
    | "admission_queue_timeout" | "queued" ->
      Some Queue
    | "first_token" | "no_first_token" | "time_to_first_token" | "ttft" ->
      Some First_token
    | "http_operation" -> Some Http_operation
    | "non_streaming_body" -> Some Non_streaming_body
    | "stream_body" -> Some Stream_body
    | "stream_idle" -> Some (Stream_idle Streaming_unknown)
    | "provider_step" -> Some Provider_step
    | "cli_stdout_idle" -> Some Cli_stdout_idle
    | "caller_budget" -> Some Caller_budget
    | "wall_clock" | "wall_clock_timeout" | "wall_exceeded" | "max_execution_time" ->
      Some Wall_clock
    | "capacity_backpressure" | "capacity_exhausted" | "client_capacity"
    | "client_capacity_full" ->
      Some Capacity_backpressure
    | "unknown_timeout" -> Some Unknown_timeout
    | _ -> None
;;

let timeout_phase_is_streaming_activity = function
  | Stream_idle state -> stream_idle_state_is_activity state
  | Admission
  | Queue
  | First_token
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Provider_step
  | Cli_stdout_idle
  | Caller_budget
  | Wall_clock
  | Capacity_backpressure
  | Unknown_timeout -> false
;;

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

let failure_scope_to_label = function
  | Invocation_scope -> "invocation"
  | Provider_scope -> "provider"
  | Turn_scope -> "turn"
  | Keeper_liveness_scope -> "keeper_liveness"
  | Fleet_scope -> "fleet"
;;

let lifecycle_effect_to_label = function
  | Keep_running -> "keep_running"
  | Soft_fail_turn -> "soft_fail_turn"
  | Pause_current_work -> "pause_current_work"
  | Force_release_turn -> "force_release_turn"
  | Pause_keeper -> "pause_keeper"
  | Restart_keeper -> "restart_keeper"
;;

let circuit_effect_to_label = function
  | Skip_circuit -> "skip_circuit"
  | Count_for_circuit -> "count_for_circuit"
  | Provider_cooldown -> "provider_cooldown"
  | Operator_breaker -> "operator_breaker"
;;

let operator_action_to_label = function
  | No_operator_action -> "none"
  | Fix_invocation -> "fix_invocation"
  | Inspect_provider_stream -> "inspect_provider_stream"
  | Inspect_timeout_budget -> "inspect_timeout_budget"
  | Reroute_or_tune_provider -> "reroute_or_tune_provider"
  | Inspect_required_tool_contract -> "inspect_required_tool_contract"
  | Reconcile_partial_commit -> "reconcile_partial_commit"
  | Inspect_keeper_liveness -> "inspect_keeper_liveness"
  | Fix_runtime_environment -> "fix_runtime_environment"
;;

let make_decision
      ~failure_scope
      ~lifecycle_effect
      ~circuit_effect
      ~operator_action
      ~keeper_death_allowed
      ~reason
  =
  { failure_scope
  ; lifecycle_effect
  ; circuit_effect
  ; operator_action
  ; keeper_death_allowed
  ; reason
  }
;;

let liveness_is_lost = function
  | Watchdog_stale | No_recent_heartbeat -> true
  | Recent_heartbeat | In_turn_progress | Unknown_liveness -> false
;;

let oas_budget_loop_effect ~phase ~strikes ~liveness =
  match phase, strikes with
  | _, Some n when n >= 3 && liveness_is_lost liveness ->
    Pause_keeper, Operator_breaker, Inspect_keeper_liveness, "oas_timeout_budget_liveness_lost"
  | _, Some n when n >= 3 ->
    Pause_current_work, Provider_cooldown, Reroute_or_tune_provider, "oas_timeout_budget_loop"
  | Some Capacity_backpressure, _ ->
    Soft_fail_turn, Provider_cooldown, Reroute_or_tune_provider, "oas_timeout_budget"
  | _ -> Soft_fail_turn, Provider_cooldown, Inspect_timeout_budget, "oas_timeout_budget"
;;

let decide = function
  | Workflow_rejection { rule_id } ->
    let reason =
      match rule_id with
      | Some rule_id -> "workflow_rejection:" ^ rule_id
      | None -> "workflow_rejection"
    in
    make_decision
      ~failure_scope:Invocation_scope
      ~lifecycle_effect:Keep_running
      ~circuit_effect:Skip_circuit
      ~operator_action:Fix_invocation
      ~keeper_death_allowed:false
      ~reason
  | Provider_timeout { phase = Some (Stream_idle state); liveness = _ } ->
    let has_activity = stream_idle_state_is_activity state in
    make_decision
      ~failure_scope:Provider_scope
      ~lifecycle_effect:Soft_fail_turn
      ~circuit_effect:Provider_cooldown
      ~operator_action:Inspect_provider_stream
      ~keeper_death_allowed:false
      ~reason:
        (if has_activity
         then "provider_stream_idle_active:" ^ stream_idle_state_to_label state
         else "provider_stream_idle:" ^ stream_idle_state_to_label state)
  | Provider_timeout { phase = Some Capacity_backpressure; liveness = _ } ->
    make_decision
      ~failure_scope:Provider_scope
      ~lifecycle_effect:Soft_fail_turn
      ~circuit_effect:Provider_cooldown
      ~operator_action:Reroute_or_tune_provider
      ~keeper_death_allowed:false
      ~reason:"provider_timeout:capacity_backpressure"
  | Provider_timeout { phase; liveness = _ } ->
    let reason =
      match phase with
      | Some phase -> "provider_timeout:" ^ timeout_phase_to_label phase
      | None -> "provider_timeout"
    in
    make_decision
      ~failure_scope:Provider_scope
      ~lifecycle_effect:Soft_fail_turn
      ~circuit_effect:Provider_cooldown
      ~operator_action:Inspect_timeout_budget
      ~keeper_death_allowed:false
      ~reason
  | Oas_timeout_budget { phase; strikes; liveness } ->
    let lifecycle_effect, circuit_effect, operator_action, reason =
      oas_budget_loop_effect ~phase ~strikes ~liveness
    in
    let reason =
      match phase with
      | Some phase -> reason ^ ":" ^ timeout_phase_to_label phase
      | None -> reason
    in
    make_decision
      ~failure_scope:Turn_scope
      ~lifecycle_effect
      ~circuit_effect
      ~operator_action
      ~keeper_death_allowed:false
      ~reason
  | Transient_provider_failure ->
    make_decision
      ~failure_scope:Provider_scope
      ~lifecycle_effect:Soft_fail_turn
      ~circuit_effect:Provider_cooldown
      ~operator_action:Reroute_or_tune_provider
      ~keeper_death_allowed:false
      ~reason:"transient_provider_failure"
  | Cascade_exhausted { retryable = true } ->
    make_decision
      ~failure_scope:Provider_scope
      ~lifecycle_effect:Soft_fail_turn
      ~circuit_effect:Provider_cooldown
      ~operator_action:Reroute_or_tune_provider
      ~keeper_death_allowed:false
      ~reason:"cascade_exhausted_retryable"
  | Cascade_exhausted { retryable = false } ->
    make_decision
      ~failure_scope:Turn_scope
      ~lifecycle_effect:Pause_current_work
      ~circuit_effect:Operator_breaker
      ~operator_action:Reroute_or_tune_provider
      ~keeper_death_allowed:false
      ~reason:"cascade_exhausted_terminal"
  | Required_tool_contract_violation ->
    make_decision
      ~failure_scope:Turn_scope
      ~lifecycle_effect:Pause_current_work
      ~circuit_effect:Skip_circuit
      ~operator_action:Inspect_required_tool_contract
      ~keeper_death_allowed:false
      ~reason:"required_tool_contract_violation"
  | Fatal_environment { detail } ->
    let reason =
      match detail with
      | Some detail -> "fatal_environment:" ^ detail
      | None -> "fatal_environment"
    in
    make_decision
      ~failure_scope:Keeper_liveness_scope
      ~lifecycle_effect:Restart_keeper
      ~circuit_effect:Operator_breaker
      ~operator_action:Fix_runtime_environment
      ~keeper_death_allowed:true
      ~reason
  | Stale_turn { progress_seen = true } ->
    make_decision
      ~failure_scope:Turn_scope
      ~lifecycle_effect:Force_release_turn
      ~circuit_effect:Operator_breaker
      ~operator_action:Inspect_timeout_budget
      ~keeper_death_allowed:false
      ~reason:"stale_turn_with_progress"
  | Stale_turn { progress_seen = false } ->
    make_decision
      ~failure_scope:Keeper_liveness_scope
      ~lifecycle_effect:Restart_keeper
      ~circuit_effect:Operator_breaker
      ~operator_action:Inspect_keeper_liveness
      ~keeper_death_allowed:true
      ~reason:"stale_turn_no_progress"
  | Stale_termination_storm { count } ->
    make_decision
      ~failure_scope:Fleet_scope
      ~lifecycle_effect:Pause_keeper
      ~circuit_effect:Operator_breaker
      ~operator_action:Inspect_keeper_liveness
      ~keeper_death_allowed:false
      ~reason:("stale_termination_storm:" ^ string_of_int count)
  | Ambiguous_partial_commit ->
    make_decision
      ~failure_scope:Turn_scope
      ~lifecycle_effect:Pause_current_work
      ~circuit_effect:Operator_breaker
      ~operator_action:Reconcile_partial_commit
      ~keeper_death_allowed:false
      ~reason:"ambiguous_partial_commit"
;;

let should_kill_keeper decision = decision.keeper_death_allowed
