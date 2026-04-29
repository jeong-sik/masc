(** Canonical metric name for proactive-scheduler skip reasons.
    Labels: [("keeper", <name>); ("reason", <skip_reason>)]. *)
val proactive_skip_reason_metric : string

val keepalive_interval_sec : unit -> int

(** Heartbeat history fallback read limits. *)
val max_history_read_bytes : int
val max_history_read_lines : int

(** Usage payload for heartbeat/status metrics rows. *)
val status_tick_usage_json : unit -> Yojson.Safe.t

val max_consecutive_heartbeat_failures : unit -> int
val max_consecutive_turn_failures : unit -> int

val write_heartbeat_snapshot :
  ctx:'a Keeper_types.context ->
  meta_current:Keeper_types.keeper_meta ->
  now_ts:float ->
  consecutive_hb_failures:int ->
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_filled:int ->
  unit
