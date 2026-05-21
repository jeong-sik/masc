(** Presence and identity sync helpers for the keeper heartbeat loop. *)

val effective_keepalive_meta :
  base_path:string ->
  fallback:Keeper_types.keeper_meta ->
  disk_meta_opt:Keeper_types.keeper_meta option ->
  Keeper_types.keeper_meta
(** Pick the freshest keeper meta available for keepalive publication. *)

val repair_identity_drift_for_keepalive :
  ctx:'a Keeper_types.context ->
  Keeper_types.keeper_meta ->
  Keeper_types.keeper_meta option
(** Repair persisted keeper identity drift before publishing heartbeat state. *)

val keeper_agent_status : Keeper_types.keeper_meta -> Masc_domain.agent_status
(** Project keeper meta into the public agent status enum. *)

val note_turn_failures_preserved_after_heartbeat :
  ctx:'a Keeper_types.context -> meta:Keeper_types.keeper_meta -> unit
(** Log when heartbeat recovery intentionally preserves turn-failure debt. *)

val sync_keeper_presence :
  ctx:'a Keeper_types.context ->
  meta_current:Keeper_types.keeper_meta ->
  t_presence_start:float ->
  consecutive_failures:int ref ->
  last_successful_heartbeat_ts:float ref ->
  work_as_hb:(unit -> bool) ->
  max_silence:(unit -> float) ->
  Keeper_types.keeper_meta
(** Publish keeper heartbeat presence and update failure counters. *)
