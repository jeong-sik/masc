(** Keeper_turn_cascade_budget_provider_timeout — Provider timeout budget resolution.

    Extracted from [Keeper_turn_cascade_budget] during godfile decomposition.
    Provider timeout budget types, constants, and resolution functions that
    determine per-attempt timeout ceilings within a keeper turn budget.

    @since God file decomposition *)

(* Retry guard floor: relaxed 30->15 (2026-04-27).
   Original 60s threshold (guard 30 + min 30) caused keeper cycle FAILED when
   remaining turn budget fell into the 30-60s band, increasing noop count and
   eventually fleet auto-pause. Field evidence (post v0.18.4): keepers hung on
   cohttp-eio bulk read for ~600s and arrived at the retry branch with <60s
   remaining -> guarded out -> cycle terminal.

   New threshold (15+15=30s) accommodates small-tail retries:
   - cohttp connect 1s + first-token 2-5s = ~6s baseline
   - 30s leaves ~9-12s headroom for actual response

   RFC-0129 (2026-05-18): the prior reserve_fraction band-aid below
   was removed. End-to-end cap chain confirmed:
     [effective_timeout_sec] ->
       [Keeper_turn_driver_try_provider.per_provider_timeout_s] ->
       [Cascade_agent_context.max_execution_time_s] ->
       [Agent_sdk.Builder.with_max_execution_time]
   plus OAS 0.195.0+ enforces a per-HTTP cap via [body_timeout_s]
   (lib/llm_provider/complete.ml:656) and per-stream-line cap via
   [stream_idle_timeout_s] ([read_sse]/[read_ndjson]). So the
   original "OAS HTTP body lacking timeout" condition no longer
   holds and the halving workaround was killing healthy slow
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
    let time_spent_in_turn = runtime.turn_timeout_sec.value -. remaining_turn_budget_s in
    let usable_retry_budget = adaptive_timeout_sec -. time_spent_in_turn in
    let wall_clock_retry_budget =
      let usable_budget = remaining_turn_budget_s -. provider_timeout_guard_sec in
      if usable_budget < min_provider_timeout_budget_sec
      then None
      else Some (Float.min adaptive_timeout_sec usable_budget)
    in
    let retry_budget =
      if remaining_turn_budget_s <= 0.0 then None
      else if usable_retry_budget >= min_provider_timeout_budget_sec then
        Some (usable_retry_budget, false)
      else if allow_wall_clock_retry_budget then
        Option.map (fun timeout -> (timeout, true)) wall_clock_retry_budget
      else None
    in
    match retry_budget with
    | None -> None
    | Some (effective_timeout_sec, used_wall_clock_retry_budget) ->
      let source =
        if used_wall_clock_retry_budget
        then "turn_budget_wall_clock_retry"
        else "turn_budget_per_attempt_retry"
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
        then "turn_budget_capped"
        else "turn_budget"
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
    ~(attempted_cascades : string list) : bool =
  is_retry
  && degraded_rotation_first_attempt
  && attempt = 1
  && List.length attempted_cascades > 1

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
