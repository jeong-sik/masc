(** Recurring-task keepalive dispatch for the keeper heartbeat loop. *)

val dispatch_recurring_keepalive :
  ctx:'a Keeper_types_profile.context ->
  meta_after_proactive:Keeper_meta_contract.keeper_meta ->
  now_ts:float ->
  int
(** Re-enable due recurring tasks, dispatch due broadcasts, and return the
    dispatch count. *)
