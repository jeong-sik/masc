(** Phase 4 durable keepalive reconciliation for the keeper supervisor. *)

val reconcile_keepalive_keepers :
  publish_lifecycle:
    (event:Keeper_lifecycle_events.lifecycle_event ->
     string ->
     string ->
     unit ->
     unit) ->
  supervise_keepalive:
    (proactive_warmup_sec:int ->
     'a Keeper_types.context ->
     Keeper_types.keeper_meta ->
     unit) ->
  'a Keeper_types.context ->
  unit
(** Re-launch durable keepalive keepers not dominated by the supervisor sweep. *)
