open Keeper_types
open Keeper_registry_types

let create ~base_path name meta ~phase ~conditions =
  let done_p, done_r = Eio.Promise.create () in
  { base_path
  ; name
  ; meta
  ; phase
  ; conditions
  ; fiber_stop = Atomic.make false
  ; fiber_wakeup = Atomic.make false
  ; event_queue = Atomic.make Keeper_event_queue.empty
  ; started_at = Time_compat.now ()
  ; grpc_close = Atomic.make None
  ; done_p
  ; done_r
  ; restart_count = 0
  ; last_restart_ts = 0.0
  ; dead_since_ts = None
  ; crash_log = []
  ; last_error = None
  ; last_failure_reason = None
  ; turn_consecutive_failures = 0
  ; last_agent_count = 0
  ; board_wakeups = StringMap.empty
  ; board_cursor_ts = 0.0
  ; board_cursor_post_id = None
  ; tool_usage = StringMap.empty
  ; transition_seq = 0
  ; waiting_for_inference = Atomic.make false
  ; last_auto_rules = None
  ; last_event_bus_correlation = None
  ; pending_turn_measurement = None
  ; current_turn_observation = None
  ; last_completed_turn = None
  ; last_skip_observation = None
  ; compaction_stage = Packed Compaction_accumulating
  }
;;
