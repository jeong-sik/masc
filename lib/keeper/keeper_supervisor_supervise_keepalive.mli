(** Keepalive supervision entry point for the keeper supervisor. *)

val supervise_keepalive :
  publish_lifecycle:
    (event:Keeper_lifecycle_events.lifecycle_event ->
     string ->
     string ->
     unit ->
     unit) ->
  launch_supervised_fiber:
    (proactive_warmup_sec:int ->
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     Keeper_registry.registry_entry ->
     (unit, Keeper_state_machine.transition_error) result) ->
  proactive_warmup_sec:int ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit
(** Register and launch a supervised keepalive fiber when spawn admission
    allows it. When the injected launch gate returns [Error _] (registry
    FSM rejection or a concurrent shutdown), no [Started]/[Running] event is
    published.  FSM rejection owns a crash settlement; shutdown rejection
    leaves terminal settlement to the shutdown transaction. *)
