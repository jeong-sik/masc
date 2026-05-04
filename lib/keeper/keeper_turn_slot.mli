exception Semaphore_wait_timeout of float

(** Global turn slot cap. Safety ceiling for ALL keeper turns. *)
val keeper_turn_throttle_limit : int

val turn_semaphore : Eio.Semaphore.t
val autonomous_turn_semaphore : Eio.Semaphore.t
val reactive_turn_semaphore : Eio.Semaphore.t

(** Wall-clock cap on [Eio.Semaphore.acquire] when waiting for a keeper
    turn slot. Derived from [MASC_KEEPER_SEMAPHORE_WAIT_TIMEOUT_SEC]. *)
val semaphore_wait_timeout_sec : float

type autonomous_waiter = {
  ticket : int;
  keeper_name : string;
}

(** Test-only reset for the autonomous FIFO wait queue. *)
val reset_autonomous_turn_queue_for_test : unit -> unit

(** Test-only snapshot of keeper names currently queued for an autonomous turn. *)
val autonomous_waiter_snapshot_for_test : unit -> string list

(** Test-only snapshots of the current semaphore availability. *)
val turn_semaphore_value_for_test : unit -> int
val autonomous_turn_semaphore_value_for_test : unit -> int
val reactive_turn_semaphore_value_for_test : unit -> int

(** Test-only FIFO queue primitives for autonomous fairness regression tests. *)
val enqueue_autonomous_waiter_for_test : string -> int
val drop_autonomous_waiter_for_test : int -> unit

(** Test-only: drive the queue-head wait loop directly with an injected
    [~started_at]. Exposed so a regression test can assert that a stale
    [started_at] (e.g. one captured before a fairness cooldown) immediately
    returns [Error `Semaphore_wait_timeout] — proving the parameter is the
    timing knob whose freshness must be controlled at every call site. *)
val wait_for_autonomous_queue_head_for_test :
  keeper_name:string ->
  ticket:int ->
  started_at:float ->
  (unit, [> `Semaphore_wait_timeout of float ]) result

(** Pure computation: seconds keeper should yield before re-entering queue
    at time [now].  0.0 = no yield needed. *)
val fairness_delay_sec_at : now:float -> keeper_name:string -> float

(** Test-only: stamp a completion time directly (bypasses [Time_compat.now]). *)
val record_autonomous_completion_at_for_test : keeper_name:string -> ts:float -> unit

(** Test-only: clear all per-keeper completion timestamps. *)
val reset_autonomous_completion_for_test : unit -> unit

(** PR-M (Leak 9): consecutive [oas_timeout_budget] cycle FAILED strikes
    per keeper. Promoted to [Keeper_fiber_crash] at this limit. *)
val oas_timeout_budget_strike_limit : int

val bump_budget_exhaustion : keeper_name:string -> int
val reset_budget_exhaustion : keeper_name:string -> unit
val peek_budget_exhaustion_for_test : keeper_name:string -> int
val set_budget_exhaustion_for_test : keeper_name:string -> strikes:int -> unit

type keeper_turn_slot_state

val with_keeper_turn_slot :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of float ]) result

(** Test-only wrapper around the keeper turn slot acquisition path. *)
val with_keeper_turn_slot_for_test :
  keeper_name:string ->
  channel:Keeper_world_observation.keeper_cycle_channel ->
  (semaphore_wait_ms:int -> 'a) ->
  ('a, [> `Semaphore_wait_timeout of float ]) result
