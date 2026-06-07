(** Keeper_turn_runtime_budget_provider_timeout — Provider timeout plan resolution.

    Extracted from [Keeper_turn_runtime_budget] during godfile decomposition.
    Provider timeout types, constants, and resolution functions that determine
    per-attempt timeout ceilings within the remaining keeper turn budget.

    @since God file decomposition *)

(* The remaining turn budget is not a keeper pause/stop reason. It is still the
   upper bound for a provider attempt's timeout, so a late attempt cannot run
   longer than the turn budget it is nested inside. Progress-based liveness
   continues to own active-stream health; this module only chooses the provider
   attempt's OAS timeout ceiling. *)

let provider_timeout_guard_sec = 15.0

let min_provider_timeout_budget_sec = 15.0

let provider_timeout_floor_sec = 0.001

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
    ~(remaining_turn_budget_s : float) : provider_timeout_budget =
  let runtime = Keeper_runtime_resolved.current () in
  let adaptive_timeout_sec = Keeper_runtime_resolved.oas_call_timeout_sec () in
  let _ = allow_wall_clock_retry_budget in
  let turn_budget_cap_sec =
    Float.max provider_timeout_floor_sec remaining_turn_budget_s
  in
  let effective_timeout_sec =
    Float.min adaptive_timeout_sec turn_budget_cap_sec
  in
  let capped_by_turn_budget = effective_timeout_sec < adaptive_timeout_sec in
  {
    effective_timeout_sec;
    adaptive_timeout_sec;
    keeper_turn_timeout_sec = runtime.turn_timeout_sec.value;
    remaining_turn_budget_sec = remaining_turn_budget_s;
    estimated_input_tokens = max 0 estimated_input_tokens;
    max_turns;
    source =
      (match is_retry, capped_by_turn_budget with
       | true, true -> "retry_limited_by_turn_budget"
       | true, false -> "retry_adaptive_timeout"
       | false, true -> "first_attempt_limited_by_turn_budget"
       | false, false -> "first_attempt_adaptive_timeout");
  }

let bounded_provider_timeout_for_turn_budget_with_turn_budget
    ~(estimated_input_tokens : int) ~(max_turns : int)
    ~(remaining_turn_budget_s : float) : float option =
  if remaining_turn_budget_s < min_provider_timeout_budget_sec
  then None
  else (
    let budget =
      resolve_bounded_provider_timeout_budget_with_turn_budget
        ~allow_wall_clock_retry_budget:false
        ~is_retry:false
        ~estimated_input_tokens
        ~max_turns
        ~remaining_turn_budget_s
    in
    Some budget.effective_timeout_sec)

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
