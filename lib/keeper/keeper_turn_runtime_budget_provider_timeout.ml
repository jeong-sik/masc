(** Keeper_turn_runtime_budget_provider_timeout — Provider timeout plan resolution.

    Extracted from [Keeper_turn_runtime_budget] during godfile decomposition.
    Provider timeout types, constants, and resolution functions that determine
    per-attempt timeout ceilings.

    @since God file decomposition *)

(* Attempts no longer consume the outer keeper-turn wall clock as an admission
   budget: a provider/liveness failure can spend the old turn cap before
   producing a first token, and denying the follow-up attempt only converts the
   real provider failure into a synthetic turn-budget failure.

   RFC-0129 (2026-05-18): the prior reserve_fraction band-aid below
   was removed. The current live-stream cap chain is progress-based:
     [Keeper_turn_driver_try_provider.per_provider_timeout_s] is not
       forwarded to [Runtime_agent_context.max_execution_time_s];
     [stream_idle_timeout_s] bounds inter-line silence; and
     [body_timeout_s] is opt-in via the explicit body-timeout override.
   So the original "OAS HTTP body lacking timeout" condition no longer
   holds and cumulative per-attempt caps must not kill healthy slow
   streams (14-event 307.5s cluster, 2026-05-17 fleet).
*)

let provider_timeout_guard_sec = 15.0

let min_provider_timeout_budget_sec = 15.0

type provider_timeout_budget = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  source : string;
}

let provider_timeout_budget_to_yojson
    (budget : provider_timeout_budget) : Yojson.Safe.t =
  `Assoc
    [
      ("provider_timeout_sec", `Float budget.effective_timeout_sec);
      ("adaptive_timeout_sec", `Float budget.adaptive_timeout_sec);
      ("keeper_turn_timeout_sec", `Float budget.keeper_turn_timeout_sec);
      ("remaining_turn_budget_sec", `Float budget.remaining_turn_budget_sec);
      ("estimated_input_tokens", `Int budget.estimated_input_tokens);
      ("source", `String budget.source);
    ]

let resolve_bounded_provider_timeout_budget_with_turn_budget
    ~(allow_wall_clock_retry_budget : bool)
    ~(is_retry : bool)
    ~(estimated_input_tokens : int)
    ~(remaining_turn_budget_s : float) : provider_timeout_budget =
  let runtime = Keeper_runtime_resolved.current () in
  let adaptive_timeout_sec = Keeper_runtime_resolved.oas_call_timeout_sec () in
  let _ = allow_wall_clock_retry_budget in
  {
    effective_timeout_sec = adaptive_timeout_sec;
    adaptive_timeout_sec;
    keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
    remaining_turn_budget_sec = remaining_turn_budget_s;
    estimated_input_tokens = max 0 estimated_input_tokens;
    source =
      (if is_retry
       then "retry_adaptive_timeout"
       else "first_attempt_adaptive_timeout");
  }

let allow_wall_clock_retry_budget_for_attempt
    ~(is_retry : bool)
    ~(degraded_rotation_first_attempt : bool)
    ~(attempt : int)
    ~(attempted_runtimes : string list) : bool =
  is_retry
  && degraded_rotation_first_attempt
  && attempt = 1
  && List.length attempted_runtimes > 1
