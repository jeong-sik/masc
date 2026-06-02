(** Pure visibility-gate primitives for the smart-heartbeat policy.

    Two concerns:
    - Cycle continuation after a [Keeper_heartbeat_smart.decision]
      (with optional [Keeper_keepalive_signal.sleep_outcome] refinement
      for the [Skip_idle + Woken] promotion case).
    - Consumer-driven idle backoff: if no SSE consumer is observing
      and no pending signal forces a cycle, downgrade [Emit] to
      [Skip_idle] until [unobserved_visibility_idle_window_s] elapses. *)

val smart_heartbeat_cycle_continues : Keeper_heartbeat_smart.decision -> bool

val cycle_continues_after_wake
  :  Keeper_heartbeat_smart.decision
  -> Keeper_keepalive_signal.sleep_outcome
  -> bool

val unobserved_visibility_idle_window_s : float
val visible_consumer_count : unit -> int

val visibility_gate_decision
  :  visible_consumers:int
  -> has_pending_signal:bool
  -> now:float
  -> last_heartbeat_cycle_ts:float
  -> Keeper_heartbeat_smart.decision
  -> Keeper_heartbeat_smart.decision
