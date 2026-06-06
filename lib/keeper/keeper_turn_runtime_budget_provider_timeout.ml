(** Keeper_turn_runtime_budget_provider_timeout — Provider timeout budget resolution.

    Extracted from [Keeper_turn_runtime_budget] during godfile decomposition.
    Provider timeout budget types, constants, and resolution functions that
    determine per-attempt timeout ceilings within a keeper turn budget.

    @since God file decomposition *)

(* First-attempt guard floor. Retry attempts no longer consume the outer
   keeper-turn wall clock as an admission budget: a provider/liveness failure
   can spend the old turn cap before producing a first token, and denying the
   follow-up retry with [retry_budget_below_min] only converts the real
   provider failure into a synthetic turn-budget failure.

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

let first_attempt_degraded_retry_reserve_sec =
  provider_timeout_guard_sec +. min_provider_timeout_budget_sec
;;

type provider_timeout_budget = {
  effective_timeout_sec : float;
  adaptive_timeout_sec : float;
  keeper_turn_timeout_sec : float;
  remaining_turn_budget_sec : float;
  estimated_input_tokens : int;
  max_turns : int;
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
      ("max_turns", `Int budget.max_turns);
      ("source", `String budget.source);
    ]

let resolve_bounded_provider_timeout_budget_with_turn_budget
    ~(allow_wall_clock_retry_budget : bool)
    ~(is_retry : bool)
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : provider_timeout_budget option =
  let runtime = Keeper_runtime_resolved.current () in
  let adaptive_timeout_sec = Keeper_runtime_resolved.oas_call_timeout_sec () in
  if is_retry then begin
    ignore allow_wall_clock_retry_budget;
    Some
      {
        effective_timeout_sec = adaptive_timeout_sec;
        adaptive_timeout_sec;
        keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
        remaining_turn_budget_sec = remaining_turn_budget_s;
        estimated_input_tokens = max 0 estimated_input_tokens;
        max_turns;
        source = "retry_adaptive_timeout";
      }
  end else begin
    let usable_budget = remaining_turn_budget_s -. provider_timeout_guard_sec in
    if usable_budget < min_provider_timeout_budget_sec
    then None
    else
      let effective_budget_ceiling =
        if
          usable_budget
          >= min_provider_timeout_budget_sec +. first_attempt_degraded_retry_reserve_sec
        then usable_budget -. first_attempt_degraded_retry_reserve_sec
        else usable_budget
      in
      let effective_timeout_sec =
        Float.min adaptive_timeout_sec effective_budget_ceiling
      in
      let capped_by_turn_budget =
        effective_timeout_sec < adaptive_timeout_sec
      in
      let source =
        if capped_by_turn_budget
        then "first_attempt_limited_by_turn_budget"
        else "first_attempt_adaptive_timeout"
      in
      Some
        {
          effective_timeout_sec;
          adaptive_timeout_sec;
          keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
          remaining_turn_budget_sec = remaining_turn_budget_s;
          estimated_input_tokens = max 0 estimated_input_tokens;
          max_turns;
          source;
        }
  end

let bounded_provider_timeout_for_turn_budget_with_turn_budget
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : float option =
  Option.map
    (fun (budget : provider_timeout_budget) -> budget.effective_timeout_sec)
    (resolve_bounded_provider_timeout_budget_with_turn_budget
       ~allow_wall_clock_retry_budget:false
       ~is_retry:false
       ~estimated_input_tokens ~max_turns ~remaining_turn_budget_s)

let allow_wall_clock_retry_budget_for_attempt
    ~(is_retry : bool)
    ~(degraded_rotation_first_attempt : bool)
    ~(attempt : int)
    ~(attempted_runtimes : string list) : bool =
  is_retry
  && degraded_rotation_first_attempt
  && attempt = 1
  && List.length attempted_runtimes > 1

let bounded_provider_timeout_for_turn_budget ~(estimated_input_tokens : int)
    ~(remaining_turn_budget_s : float) : float option =
  bounded_provider_timeout_for_turn_budget_with_turn_budget ~estimated_input_tokens
    ~max_turns:(Keeper_runtime_resolved.reactive_max_turns_per_call ())
    ~remaining_turn_budget_s

let provider_retry_budget_available_for_turn
    ~(allow_wall_clock_retry_budget : bool) ~(is_retry : bool)
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : bool =
  Option.is_some
    (resolve_bounded_provider_timeout_budget_with_turn_budget
       ~allow_wall_clock_retry_budget
       ~is_retry ~estimated_input_tokens
       ~max_turns ~remaining_turn_budget_s)
