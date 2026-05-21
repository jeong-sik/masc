(** Reconcile-gate restore path for the keeper supervisor. *)

val restore_reconcile_continue_gate :
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types.context ->
     Keeper_types.keeper_meta ->
     unit) ->
  'a Keeper_types.context ->
  Keeper_types.keeper_meta ->
  unit
(** Rehydrate a persisted reconcile approval gate for a paused keeper. *)
