(** Heartbeat snapshot persistence and stage-timing ring-buffer helpers. *)

val maybe_write_heartbeat_snapshot :
  ctx:'a Keeper_types_profile.context ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  now_ts:float ->
  last_snapshot_ts:float ref ->
  snapshot_interval_sec:int ->
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_filled:int ->
  unit
(** Write the heartbeat snapshot when the snapshot interval has elapsed. *)

val record_keepalive_stage_timing :
  timing_ring:Keeper_keepalive_signal.stage_timing array ->
  timing_cursor:int ref ->
  timing_filled:int ref ->
  ring_sz:int ->
  t_presence_start:float ->
  t_presence_end:float ->
  t_snapshot_start:float ->
  t_snapshot_end:float ->
  t_board_start:float ->
  t_board_end:float ->
  t_turn_start:float ->
  t_turn_end:float ->
  unit
(** Record one keepalive cycle's stage timing in the ring buffer. *)
