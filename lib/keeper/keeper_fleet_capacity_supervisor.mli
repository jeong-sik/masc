(** Fleet Capacity Supervisor — pure tick core (RFC-0130 PR-2).

    Closes the loop on [reaction_capacity_shortfall_count] (PR #16050)
    by converting the typed shortfall signal into a typed spawn decision.
    The decision is closed and total; probe-unknown failure modes are
    fail-closed at the admission boundary (matches RFC-0124 §2.2).

    This module is intentionally I/O-free. [tick] is a deterministic
    pure function over [observation]. The side-effecting [execute]
    wrapper lives in a later PR (PR-4 per the RFC phased rollout). *)

module Spawn_reason : sig
  type t =
    | Below_target_reaction_capacity
    | Below_minimum_running_fibers
    | Recovery_from_cold_start

  val to_string : t -> string
end

module Backpressure_reason : sig
  type t =
    | Admission_queue_saturated
    | Disk_pressure_active
    | Fd_pressure_active

  val to_string : t -> string
end

module Noop_reason : sig
  type t =
    | Capacity_at_target
    | Capacity_above_target
    | Already_recently_acted

  val to_string : t -> string
end

type observation =
  { running_keeper_fiber_count : int
  ; target_reaction_capacity_count : int
  ; minimum_running_fibers : int
  ; reaction_capacity_shortfall_count : int
  ; admission_blocked_count : int
  ; admission_queue_saturated_cap : int
  ; disk_pressure_active : bool
  ; fd_pressure_active : bool
  ; cold_start_in_progress : bool
  ; now : float
  ; last_action_at : float option
  ; cooldown_seconds : float
  }

type spawn_request =
  { reason : Spawn_reason.t
  ; suggested_keeper_count : int
  }

type decision =
  | Spawn of spawn_request
  | Backpressure of Backpressure_reason.t
  | Noop of Noop_reason.t

val decision_to_string : decision -> string

val tick : observation -> decision
(** Pure, total, deterministic.

    Priority order (first matching rule wins):
    1. Disk pressure → [Backpressure Disk_pressure_active]
    2. Fd pressure → [Backpressure Fd_pressure_active]
    3. Admission queue saturated (blocked > cap) →
       [Backpressure Admission_queue_saturated]
    4. Cooldown not elapsed → [Noop Already_recently_acted]
    5. Cold start in progress → [Spawn Recovery_from_cold_start]
    6. Running < minimum margin → [Spawn Below_minimum_running_fibers]
    7. Shortfall > 0 → [Spawn Below_target_reaction_capacity]
    8. Running > target → [Noop Capacity_above_target]
    9. Otherwise → [Noop Capacity_at_target] *)
