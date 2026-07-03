(** Reconcile-gate resume path for the keeper supervisor. *)

val resume_keeper_after_reconcile_gate :
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     unit) ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit
(** Clear the persisted reconcile blocker/latch and resume or relaunch the keeper. *)
