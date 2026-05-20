(* Pure visibility-gate primitives for the smart-heartbeat policy.

   Two layers:

   1. [smart_heartbeat_cycle_continues] / [cycle_continues_after_wake]:
      decide whether a [Skip_idle] decision should still permit cycle
      progress (after a wake signal).
   2. [visibility_gate_decision]: downgrade [Emit] to [Skip_idle] when
      no SSE consumer is observing and no pending signal demands a
      cycle (consumer-driven idle backoff).

   Extracted from [Keeper_heartbeat_loop] (godfile decomp). Pure
   functions over typed inputs - no I/O, no shared state. Side input
   on [visible_consumer_count] is the live SSE registry, kept here
   because the read is the only purpose of the helper. *)

let smart_heartbeat_cycle_continues (d : Keeper_heartbeat_smart.decision) : bool =
  match d with
  | Keeper_heartbeat_smart.Skip_busy | Keeper_heartbeat_smart.Emit -> true
  | Keeper_heartbeat_smart.Skip_idle _ -> false
;;

let cycle_continues_after_wake
      (d : Keeper_heartbeat_smart.decision)
      (outcome : Keeper_keepalive_signal.sleep_outcome)
  : bool
  =
  match d, outcome with
  | Keeper_heartbeat_smart.Skip_idle _, Keeper_keepalive_signal.Woken -> true
  | _, _ -> smart_heartbeat_cycle_continues d
;;

let unobserved_visibility_idle_window_s = 900.0

let visible_consumer_count () =
  Sse.client_count_by_kind Sse.Observer + Sse.external_subscriber_count ()
;;

let visibility_gate_decision
      ~(visible_consumers : int)
      ~(has_pending_signal : bool)
      ~(now : float)
      ~(last_heartbeat_cycle_ts : float)
      (decision : Keeper_heartbeat_smart.decision)
  : Keeper_heartbeat_smart.decision
  =
  match decision with
  | Keeper_heartbeat_smart.Emit
    when visible_consumers <= 0
         && (not has_pending_signal)
         && last_heartbeat_cycle_ts > 0.0
         && now -. last_heartbeat_cycle_ts < unobserved_visibility_idle_window_s ->
    Keeper_heartbeat_smart.Skip_idle
      (last_heartbeat_cycle_ts +. unobserved_visibility_idle_window_s)
  | _ -> decision
;;
