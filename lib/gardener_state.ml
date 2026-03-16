(** Gardener_state — mutable state, circuit breaker, budget, config loading,
    and recording helpers. *)

[@@@warning "-32-69"]

open Gardener_types

(** {1 Configuration Loading} *)

let load_config () : gardener_config = {
  enabled = Env_config.Gardener.enabled;
  min_agents = Env_config.Gardener.min_agents;
  max_agents = Env_config.Gardener.max_agents;
  target_agents = Env_config.Gardener.target_agents;
  max_daily_spawns = Env_config.Gardener.max_daily_spawns;
  max_daily_retirements = Env_config.Gardener.max_daily_retirements;
  spawn_cooldown_sec = Env_config.Gardener.spawn_cooldown_sec;
  retirement_cooldown_sec = Env_config.Gardener.retirement_cooldown_sec;
  use_llm_decision = Env_config.Gardener.use_llm_decision;
  gap_maturity_hours = Env_config.Gardener.gap_maturity_hours;
  idle_threshold_hours = Env_config.Gardener.idle_threshold_hours;
  retirement_grace_sec = Env_config.Gardener.retirement_grace_sec;
  max_consecutive_failures = Env_config.Gardener.max_consecutive_failures;
  circuit_cooldown_sec = Env_config.Gardener.circuit_cooldown_sec;
  check_interval_sec = Env_config.Gardener.check_interval_sec;
}

let gardener_state_ref : gardener_state option ref = ref None
let gardener_lock : Eio.Mutex.t option ref = ref None
let room_config_ref : Room_utils.config option ref = ref None

(** Execute [f] with lock if available, otherwise directly.
    Safe for single-threaded test scenarios (no Eio runtime). *)
let with_lock f =
  match !gardener_lock with
  | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex f
  | None -> f ()  (* Test mode: no concurrent access expected *)

(** Get or create the singleton state.
    Initialization is NOT locked — safe because:
    1. In production, [start] creates lock before forking fibers
    2. In tests, single-threaded access means no race
    3. Worst case: double init creates identical state *)
let get_state () =
  match !gardener_state_ref with
  | Some s -> s
  | None ->
      let s = make_gardener_state () in
      gardener_state_ref := Some s;
      s

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let json_string_of_float_ts ts =
  if ts > 0.0 then `String (iso_of_unix ts) else `Null

let json_string_of_opt_ts = function
  | Some ts when ts > 0.0 -> `String (iso_of_unix ts)
  | _ -> `Null

let json_string_of_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed

type decision_snapshot = {
  intervention : intervention;
  source : string;
  reason : string;
  target : string;
  error : string;
}

let intervention_name = function
  | NeedSpawn _ -> "need_spawn"
  | NeedWorker _ -> "need_worker"
  | NeedRetirement _ -> "need_retirement"
  | Balanced -> "balanced"

let intervention_target = function
  | NeedSpawn gap -> gap.topic
  | NeedRetirement stats -> stats.name
  | NeedWorker _ | Balanced -> ""

let mark_tick_start () =
  let now = Time_compat.now () in
  with_lock (fun () ->
      let state = get_state () in
      state.tick_count <- state.tick_count + 1;
      state.last_tick_started_at <- now;
      state.last_error <- "";
      state.last_action <- "none";
      state.last_target <- "";
      state.last_reason <- "";
      state.last_intervention <- "none";
      state.last_decision_source <- "none");
  now

let record_health_summary ~(at : float) (health : ecosystem_health) =
  with_lock (fun () ->
      let state = get_state () in
      state.last_health_check <- at;
      state.last_total_agents <- health.total_agents;
      state.last_active_agents <- health.active_agents;
      state.last_idle_agents <- health.idle_agents;
      state.last_todo_count <- health.task_backlog.todo_count;
      state.last_high_priority_todo <- health.task_backlog.high_priority_todo;
      state.last_orphan_count <- health.task_backlog.orphan_count;
      state.last_homeostatic_score <- health.homeostatic_score;
      state.last_needs_workers <- health.needs_workers)

let record_decision (decision : decision_snapshot) =
  with_lock (fun () ->
      let state = get_state () in
      state.last_intervention <- intervention_name decision.intervention;
      state.last_decision_source <- decision.source;
      state.last_reason <- decision.reason;
      state.last_target <- decision.target;
      if String.trim decision.error <> "" then state.last_error <- decision.error)

let record_action ?target ?reason ?error action =
  with_lock (fun () ->
      let state = get_state () in
      state.last_action <- action;
      (match target with Some value when String.trim value <> "" -> state.last_target <- value | _ -> ());
      (match reason with Some value when String.trim value <> "" -> state.last_reason <- value | _ -> ());
      (match error with Some value when String.trim value <> "" -> state.last_error <- value | _ -> ()))

let record_tick_complete () =
  let now = Time_compat.now () in
  with_lock (fun () ->
      let state = get_state () in
      state.last_tick_completed_at <- now)

(** {1 Circuit Breaker} *)

let is_circuit_open () =
  let state = get_state () in
  match state.circuit_open_until with
  | None -> false
  | Some until -> Time_compat.now () < until

let trip_circuit ~config =
  let state = get_state () in
  state.consecutive_failures <- state.consecutive_failures + 1;
  if state.consecutive_failures >= config.max_consecutive_failures then begin
    let until = Time_compat.now () +. config.circuit_cooldown_sec in
    state.circuit_open_until <- Some until;
    Eio.traceln "[Gardener] Circuit OPEN until %.0f (consecutive failures: %d)"
      until state.consecutive_failures
  end

let reset_circuit () =
  let state = get_state () in
  state.consecutive_failures <- 0;
  state.circuit_open_until <- None

(** {1 Budget Management} *)

let reset_daily_budgets_if_needed () =
  let state = get_state () in
  let now = Time_compat.now () in
  let day_elapsed = now -. state.day_start in
  if day_elapsed > 86400.0 then begin
    state.day_start <- now;
    state.spawns_today <- 0;
    state.retirements_today <- 0;
    Eio.traceln "[Gardener] Daily budgets reset"
  end

let can_spawn ~config =
  reset_daily_budgets_if_needed ();
  let state = get_state () in
  let now = Time_compat.now () in
  let cooldown_ok = (now -. state.last_spawn_attempt) > config.spawn_cooldown_sec in
  let budget_ok = state.spawns_today < config.max_daily_spawns in
  let circuit_ok = not (is_circuit_open ()) in
  cooldown_ok && budget_ok && circuit_ok

let can_retire ~config =
  reset_daily_budgets_if_needed ();
  let state = get_state () in
  let now = Time_compat.now () in
  let cooldown_ok = (now -. state.last_retirement_attempt) > config.retirement_cooldown_sec in
  let budget_ok = state.retirements_today < config.max_daily_retirements in
  let circuit_ok = not (is_circuit_open ()) in
  cooldown_ok && budget_ok && circuit_ok

let record_spawn () =
  let state = get_state () in
  state.spawns_today <- state.spawns_today + 1;
  state.last_spawn_attempt <- Time_compat.now ()

let record_retirement () =
  let state = get_state () in
  state.retirements_today <- state.retirements_today + 1;
  state.last_retirement_attempt <- Time_compat.now ()

