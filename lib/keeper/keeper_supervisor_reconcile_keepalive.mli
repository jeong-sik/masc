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
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     unit) ->
  load_or_materialize_keeper_meta:
    ('a Keeper_types_profile.context ->
     string ->
     (Keeper_meta_contract.keeper_meta option, string) result) ->
  'a Keeper_types_profile.context ->
  unit
(** Re-launch durable keepalive keepers not dominated by the supervisor sweep.
    Missing configured keepers are materialized through the required callback;
    per-keeper failures are logged/metriced without aborting the whole pass. *)
