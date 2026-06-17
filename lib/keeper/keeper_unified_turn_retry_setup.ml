type retry_setup =
  { timeout_sec : float
  ; turn_started_at : float
  ; turn_deadline : float
  ; remaining_turn_budget_s : unit -> float
  ; elapsed_ms : float -> int
  ; current_turn_phase_elapsed_ms : float option -> int * int option
  ; keeper_profile : Keeper_types_profile.keeper_profile_defaults
  ; max_idle_turns : int
  ; max_turns : int
  }

let build ~now ~keeper_name ~channel ~turn_affordances =
  let timeout_sec = Keeper_runtime_resolved.turn_timeout_sec () in
  let turn_started_at = now () in
  let turn_deadline = turn_started_at +. timeout_sec in
  let remaining_turn_budget_s () = Float.max 0.0 (turn_deadline -. now ()) in
  let elapsed_ms seconds = int_of_float (Float.max 0.0 seconds *. 1000.0) in
  let current_turn_phase_elapsed_ms retry_phase_started_at =
    let now_s = now () in
    match retry_phase_started_at with
    | None -> elapsed_ms (now_s -. turn_started_at), Some 0
    | Some retry_started_at ->
      ( elapsed_ms (retry_started_at -. turn_started_at)
      , Some (elapsed_ms (now_s -. retry_started_at)) )
  in
  let keeper_profile = Keeper_types_profile.load_keeper_profile_defaults keeper_name in
  let max_idle_turns, max_turns =
    match channel with
    | Keeper_world_observation.Reactive ->
      ( Keeper_runtime_resolved.reactive_max_idle_turns ()
      , Keeper_types_profile.effective_max_turns_per_call keeper_profile )
    | Keeper_world_observation.Scheduled_autonomous ->
      ( Keeper_runtime_resolved.autonomous_max_idle_turns ()
      , Keeper_types_profile.effective_max_turns_per_call_scheduled_autonomous
          keeper_profile )
  in
  ignore turn_affordances;
  { timeout_sec
  ; turn_started_at
  ; turn_deadline
  ; remaining_turn_budget_s
  ; elapsed_ms
  ; current_turn_phase_elapsed_ms
  ; keeper_profile
  ; max_idle_turns
  ; max_turns
  }
