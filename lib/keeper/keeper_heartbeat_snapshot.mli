val keepalive_interval_sec : unit -> int

(** Heartbeat history fallback read limits. *)
val max_history_read_bytes : int
val max_history_read_lines : int

(** Usage payload for heartbeat/status metrics rows. *)
val status_tick_usage_json : unit -> Yojson.Safe.t


val write_heartbeat_snapshot :
  ctx:'a Keeper_types_profile.context ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  now_ts:float ->
  consecutive_hb_failures:int ->
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_filled:int ->
  unit
