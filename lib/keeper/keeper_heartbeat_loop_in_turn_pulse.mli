(** In-turn liveness pulse helpers for the keeper heartbeat loop. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val in_turn_liveness_pulse_interval_sec : unit -> float

val in_flight_elapsed_ms : now_ts:float -> started_at:float -> float
(** #27349: raw milliseconds since the turn started, floored at 0. No
    threshold -- a consumer (dashboard, future supervision seat) judges
    staleness; this only reports the fact. *)

val since_last_progress_ms : now_ts:float -> last_progress_at:float -> float
(** #27349: raw milliseconds since the turn's last recorded progress event,
    floored at 0. A turn making steady progress stays near zero even when
    long-running; a stalled provider call grows unbounded. *)

val emit_in_turn_liveness_pulse :
  ctx:_ context -> meta:keeper_meta -> unit

val with_in_turn_liveness_pulse :
  ctx:_ context -> meta:keeper_meta -> stop:bool Atomic.t -> (unit -> 'a) -> 'a
