(** Recurring-task keepalive dispatch for the keeper heartbeat loop. *)

val dispatch_recurring_keepalive :
  ctx:'a Keeper_types.context ->
  meta_after_proactive:Keeper_types.keeper_meta ->
  now_ts:float ->
  int
(** Re-enable due recurring tasks, dispatch due broadcasts, and return the
    dispatch count. *)
