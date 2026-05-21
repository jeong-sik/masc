(** Reconcile-gate resume path for the keeper supervisor. *)

val resume_keeper_after_reconcile_gate :
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types.context ->
     Keeper_types.keeper_meta ->
     unit) ->
  'a Keeper_types.context ->
  Keeper_types.keeper_meta ->
  unit
(** Clear the persisted reconcile blocker and resume or relaunch the keeper. *)
