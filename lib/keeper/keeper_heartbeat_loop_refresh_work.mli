(** Work-as-heartbeat refresher for keeper heartbeat loop state. *)

val refresh_work_as_heartbeat :
  ctx:_ Keeper_types.context ->
  meta_after_proactive:Keeper_types.keeper_meta ->
  proactive_warmup_elapsed:bool ->
  work_as_hb:(unit -> bool) ->
  last_successful_heartbeat_ts:float ref ->
  consecutive_failures:int ref ->
  unit
(** Treat recent productive work as heartbeat evidence when a regular
    heartbeat succeeds for any joined room. *)
