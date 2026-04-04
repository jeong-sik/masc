(** Smart Heartbeat - Token-saving heartbeat logic

    Implements OpenClaw-style adaptive heartbeat to reduce token consumption
    and SSE traffic by intelligently skipping unnecessary heartbeats.

    Strategy:
    1. Busy Skip: When agent is actively working on a task, heartbeats are
       unnecessary as task operations already prove liveness.
    2. Idle Multiplier: When agent has been idle for > 5 minutes, increase
       the heartbeat interval (default 3x) since idle agents need less
       frequent liveness checks.

    Token Savings Estimate:
    - 60-80% reduction in heartbeat broadcasts during typical sessions
    - Busy periods: 100% reduction (task ops prove liveness)
    - Idle periods: 66% reduction (3x interval)
*)

type config = {
  base_interval_s: float;
  idle_multiplier: float;
  busy_skip: bool;
  idle_threshold_s: float;
}

type decision =
  | Emit
  | Skip_busy
  | Skip_idle of float

(** SSOT: [Env_config.SmartHeartbeatTuning] for base values and clamp bounds. *)
let default_config = {
  base_interval_s = Env_config.SmartHeartbeatTuning.base_interval_s;
  idle_multiplier = Env_config.SmartHeartbeatTuning.idle_multiplier;
  busy_skip = true;
  idle_threshold_s = Env_config.SmartHeartbeatTuning.idle_threshold_s;
}

let make_config
    ?(base_interval_s = Env_config.SmartHeartbeatTuning.base_interval_s)
    ?(idle_multiplier = Env_config.SmartHeartbeatTuning.idle_multiplier)
    ?(busy_skip = true)
    ?(idle_threshold_s = Env_config.SmartHeartbeatTuning.idle_threshold_s)
    () =
  (* Clamp caller overrides to same bounds as Env_config defaults *)
  let base_interval_s = Float.max 5.0 (Float.min 300.0 base_interval_s) in
  let idle_multiplier = Float.max 1.0 (Float.min 10.0 idle_multiplier) in
  let idle_threshold_s = Float.max 60.0 (Float.min 3600.0 idle_threshold_s) in
  { base_interval_s; idle_multiplier; busy_skip; idle_threshold_s }

let effective_interval ~config ~last_activity =
  let now = Time_compat.now () in
  let idle_duration = now -. last_activity in
  if idle_duration > config.idle_threshold_s then
    config.base_interval_s *. config.idle_multiplier
  else
    config.base_interval_s

let should_emit ~config ~agent_status ~last_activity ~last_heartbeat =
  let now = Time_compat.now () in

  (* Rule 1: Skip if busy and busy_skip is enabled *)
  if config.busy_skip && agent_status = Types.Busy then
    Skip_busy
  else
    let interval = effective_interval ~config ~last_activity in
    let time_since_last = now -. last_heartbeat in

    if time_since_last >= interval then
      Emit
    else
      (* Calculate next emit time *)
      let next_emit = last_heartbeat +. interval in
      Skip_idle next_emit

let decision_to_string = function
  | Emit -> "emit"
  | Skip_busy -> "skip:busy"
  | Skip_idle next ->
      let wait = next -. Time_compat.now () in
      Printf.sprintf "skip:idle(next in %.1fs)" (max 0.0 wait)

let should_emit_now = function
  | Emit -> true
  | Skip_busy | Skip_idle _ -> false
