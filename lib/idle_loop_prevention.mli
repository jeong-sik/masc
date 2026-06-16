(** Idle loop prevention — Scheduler backoff system interface.

    Phase 1 implementation (task-1303) based on rondo's task-1119 design.
    Provides a cooldown-ladder mechanism that progressively increases
    wait time between consecutive no-op turns.
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

(** Outcome of a single turn: productive work or a no-op category. *)
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

(** Opaque mutable backoff state type. *)
type t

(** Default drain configuration. *)
val default_config : drain_config

(** Create a fresh backoff state. Config optional, defaults to [default_config]. *)
val create : ?config:drain_config -> unit -> t

(** Record a turn outcome and return (current_cooldown_sec, state).

    - Productive turn: resets consecutive_noops to 0, resets cooldown to base.
    - Noop turn: increments consecutive_noops, computes cooldown via ladder,
      sets next_eligible_at = now + cooldown.
*)
val record_turn : t -> turn_outcome -> float * t

(** Check if the keeper is eligible to run a turn now (time >= next_eligible_at). *)
val eligible_now : t -> bool

(** Reset the backoff state to fresh defaults. *)
val reset : t -> unit

(** Set the current utilization value (0.0–1.0) for feedback adjustment. *)
val set_utilization : t -> float -> unit

(** Get a human-readable description of the noop_kind. *)
val noop_kind_description : noop_kind -> string

(** Get the current backoff state summary for telemetry/logging. *)
val state_summary : t -> string