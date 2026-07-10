(** Reconcile-gate resume path for the keeper supervisor. *)

val resume_keeper_after_reconcile_gate :
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     unit) ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  gate_id:string ->
  unit ->
  unit
(** Clear the persisted reconcile blocker/latch and return the wake/relaunch
    action that must run only after the blocking approval leaves the queue. *)
