(** Idle loop prevention — Scheduler backoff system for keeper turn dispatch.

    Provides a cooldown-ladder mechanism that progressively increases
    wait time between consecutive no-op turns. A productive turn resets
    the ladder. Utilization feedback adjusts the cooldown multiplier.

    Phase 1 implementation (task-1303) based on rondo's task-1119 design:
    - drain_config with tunable parameters
    - backoff_state with mutable counters
    - compute_cooldown ladder (exponential tiers)
    - utilization feedback adjustment
    - productive_ratio halving
*)

(** Categories of no-operation outcomes. *)
type noop_kind =
  | Stay_silent
  | Stale_list
  | Read_no_signal
  | Duplicate_claim
  | Heartbeat
  | BoardScan
  | TaskSearch
  | MemoryStaleness
  | ExternalWait
  | Blocked_transition

(** Outcome of a single turn. *)
type turn_outcome =
  | Productive
  | Noop of noop_kind

(** Configuration for the backoff system. *)
type drain_config = {
  max_consecutive_noop : int;
  cooldown_base_sec : float;
  cooldown_backoff : float;
  cooldown_max_sec : float;
  util_target : float;
  history_window : int;
}

(** Mutable state tracking backoff progression. *)
type t = {
  mutable consecutive_noops : int;
  mutable current_cooldown_sec : float;
  mutable productive_count : int;
  mutable total_turns : int;
  mutable next_eligible_at : float;
  mutable last_utilization : float;
  config : drain_config;
}

(** Default drain configuration. *)
let default_config : drain_config = {
  max_consecutive_noop = 3;
  cooldown_base_sec = 300.0;
  cooldown_backoff = 2.0;
  cooldown_max_sec = 3600.0;
  util_target = 0.30;
  history_window = 50;
}

(** Create a fresh backoff state with the given config. *)
let create ?(config = default_config) () : t = {
  consecutive_noops = 0;
  current_cooldown_sec = config.cooldown_base_sec;
  productive_count = 0;
  total_turns = 0;
  next_eligible_at = 0.0;
  last_utilization = 0.0;
  config;
}

(** Compute the cooldown seconds based on the number of consecutive no-ops.

    Backoff ladder:
      noops 1-3  → cooldown ×1  (base, default 300s)
      noops 4-7  → cooldown ×2  (default 600s)
      noops 8-15 → cooldown ×4  (default 1200s)
      noops 16+  → cooldown ×8  (up to cooldown_max_sec, default 3600s)

    Utilization adjustment:
      util < 20% → apply 1.5× multiplier
      productive_ratio > 0.5 → halve cooldown
*)
let compute_cooldown (state : t) : float =
  let base = state.config.cooldown_base_sec in
  let raw =
    if state.consecutive_noops <= 3 then
      base
    else if state.consecutive_noops <= 7 then
      base *. 2.0
    else if state.consecutive_noops <= 15 then
      base *. 4.0
    else
      base *. 8.0
  in
  (* Cap at maximum *)
  let capped = min raw state.config.cooldown_max_sec in
  (* Utilization adjustment: apply 1.5× if util < 20% *)
  let util_adj =
    if state.last_utilization > 0.0 && state.last_utilization < 0.20 then
      capped *. 1.5
    else
      capped
  in
  (* Productive ratio halving: if > 50% of recent turns were productive, halve *)
  let productive_ratio =
    if state.total_turns > 0 then
      float state.productive_count /. float state.total_turns
    else
      0.0
  in
  if productive_ratio > 0.5 then
    max (util_adj /. 2.0) state.config.cooldown_base_sec
  else
    max util_adj state.config.cooldown_base_sec

(** Record a turn outcome and return (cooldown_sec, updated_state). *)
let record_turn (state : t) (outcome : turn_outcome) : float * t =
  state.total_turns <- state.total_turns + 1;
  match outcome with
  | Productive ->
    state.consecutive_noops <- 0;
    state.productive_count <- state.productive_count + 1;
    state.current_cooldown_sec <- state.config.cooldown_base_sec;
    state.next_eligible_at <- Unix.time ();
    (state.current_cooldown_sec, state)
  | Noop _ ->
    state.consecutive_noops <- state.consecutive_noops + 1;
    let cooldown = compute_cooldown state in
    state.current_cooldown_sec <- cooldown;
    state.next_eligible_at <- Unix.time () +. cooldown;
    (cooldown, state)

(** Check if the keeper is eligible to run a turn now. *)
let eligible_now (state : t) : bool =
  Unix.time () >= state.next_eligible_at

(** Reset the backoff state to fresh defaults. *)
let reset (state : t) : unit =
  state.consecutive_noops <- 0;
  state.current_cooldown_sec <- state.config.cooldown_base_sec;
  state.productive_count <- 0;
  state.total_turns <- 0;
  state.next_eligible_at <- 0.0

(** Set the current utilization value (0.0–1.0) for feedback adjustment. *)
let set_utilization (state : t) (util : float) : unit =
  state.last_utilization <- util

(** Get a human-readable description of the noop_kind. *)
let noop_kind_description = function
  | Stay_silent -> "stay_silent"
  | Stale_list -> "stale_list"
  | Read_no_signal -> "read_no_signal"
  | Duplicate_claim -> "duplicate_claim"
  | Heartbeat -> "heartbeat"
  | BoardScan -> "board_scan"
  | TaskSearch -> "task_search"
  | MemoryStaleness -> "memory_staleness"
  | ExternalWait -> "external_wait"
  | Blocked_transition -> "blocked_transition"

(** Get the current backoff state summary for telemetry/logging. *)
let state_summary (state : t) : string =
  Printf.sprintf "noops=%d cooldown=%.0fs eligible_at=%.0f prod=%d total=%d util=%.2f"
    state.consecutive_noops
    state.current_cooldown_sec
    state.next_eligible_at
    state.productive_count
    state.total_turns
    state.last_utilization