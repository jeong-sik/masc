(** Completion-contract latch recovery for the unified keeper turn.

    Parallel of {!Keeper_unified_turn_no_progress} but for the
    completion-contract violation branch.

    Problem (RFC-0047 §3.2 / plan hypothesis B): an operator-triggered
    resume on a keeper latched by a completion-contract violation
    previously cleared [paused], [last_blocker], [failure_reason],
    [turn_consecutive_failures] — but did *not* clear the
    completion-contract detector state. On the very next cycle the
    detector fired again, the 3-strike gate re-engaged, and the keeper
    re-paused within seconds. Operators reported "resume doesn't stick".

    Fix: surface a typed recovery helper parallel to
    [Keeper_unified_turn_no_progress.clear_for_operator_resume] so the
    resume path can clear both latches in one shot.

    This module is purely additive: it does NOT introduce new pause or
    escalation behavior. New automatic pause/escalation logic is
    deliberately out of scope for this PR. *)

let failure_reason_code = "completion_contract_violation"

let failure_reason_is_completion_contract = function
  | Keeper_registry.Completion_contract_violation _ -> true
  | Keeper_registry.Provider_runtime_error { code; _ } ->
    String.equal code failure_reason_code
  | Keeper_registry.Heartbeat_consecutive_failures _
  | Keeper_registry.Turn_consecutive_failures _
  | Keeper_registry.Stale_turn_timeout _
  | Keeper_registry.Stale_termination_storm _
  | Keeper_registry.Stale_fleet_batch _
  | Keeper_registry.Provider_timeout_loop _
  | Keeper_registry.Ambiguous_partial_commit _
  | Keeper_registry.Fiber_unresolved _
  | Keeper_registry.Exception _
  | Keeper_registry.Turn_overflow_pause
  | Keeper_registry.Turn_livelock_pause
  | Keeper_registry.Operator_interrupt ->
    false
;;

let blocker_is_completion_contract = function
  | Keeper_meta_contract.Completion_contract_violation -> true
  | Keeper_meta_contract.Runtime_exhausted _
  | Keeper_meta_contract.Capacity_backpressure
  | Keeper_meta_contract.Ambiguous_post_commit_timeout
  | Keeper_meta_contract.Ambiguous_post_commit_failure
  | Keeper_meta_contract.Admission_queue_wait_timeout
  | Keeper_meta_contract.Turn_timeout_after_queue_wait
  | Keeper_meta_contract.Turn_timeout
  | Keeper_meta_contract.Turn_livelock_blocked
  | Keeper_meta_contract.No_progress_loop
  | Keeper_meta_contract.Fiber_unresolved
  | Keeper_meta_contract.Stale_turn_timeout
  | Keeper_meta_contract.Stale_fleet_batch
  | Keeper_meta_contract.Oas_agent_execution_timeout
  | Keeper_meta_contract.Sdk_max_turns_exceeded
  | Keeper_meta_contract.Sdk_token_budget_exceeded
  | Keeper_meta_contract.Sdk_cost_budget_exceeded
  | Keeper_meta_contract.Sdk_unrecognized_stop_reason
  | Keeper_meta_contract.Sdk_idle_detected
  | Keeper_meta_contract.Sdk_guardrail_violation
  | Keeper_meta_contract.Sdk_tripwire_violation
  | Keeper_meta_contract.Sdk_exit_condition_met
  | Keeper_meta_contract.Sdk_input_required ->
    false
;;

(** Clear the completion-contract latch for an operator-driven resume.

    Resets:
    - The [Keeper_registry.last_failure_reason] when it is the typed
      [Completion_contract_violation] failure, plus the legacy
      provider-runtime code kept for on-disk compatibility.
    - The [Keeper_meta_contract.runtime.last_blocker] when its klass
      is [Completion_contract_violation].

    Returns the (possibly mutated) meta. Does not touch paused state,
    turn_consecutive_failures, or any other field — those are the
    resume_reconcile_gate's responsibility.

    @param base_path  Keeper registry on-disk root.
    @param meta       Current keeper meta snapshot. *)
let clear_for_operator_resume ~base_path meta =
  let keeper_name = meta.Keeper_meta_contract.name in
  let cleared_failure_reason =
    match Keeper_registry.get ~base_path keeper_name with
    | Some { Keeper_registry.last_failure_reason = Some reason; _ }
      when failure_reason_is_completion_contract reason ->
      Keeper_registry.set_failure_reason ~base_path keeper_name None;
      true
    | Some { Keeper_registry.last_failure_reason = Some reason; _ } ->
      let (_ : Keeper_registry.failure_reason) = reason in
      false
    | Some { Keeper_registry.last_failure_reason = None; _ } -> false
    | None -> false
  in
  let cleared_meta_blocker =
    match meta.runtime.last_blocker with
    | Some { Keeper_meta_contract.klass; _ } -> blocker_is_completion_contract klass
    | None -> false
  in
  if cleared_failure_reason || cleared_meta_blocker then
    Log.Keeper.info
      "%s: operator resume cleared completion_contract_violation latch \
       (failure_reason=%b meta_blocker=%b)"
      keeper_name
      cleared_failure_reason
      cleared_meta_blocker;
  if cleared_meta_blocker then
    Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  else
    meta
;;
