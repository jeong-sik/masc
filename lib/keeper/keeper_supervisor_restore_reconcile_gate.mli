(** Reconcile-gate restore path for the keeper supervisor. *)

val restore_reconcile_continue_gate :
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     unit) ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit
(** Rehydrate a persisted reconcile approval gate for a paused keeper. *)
