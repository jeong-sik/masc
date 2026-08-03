(** Keepalive supervision entry point for the keeper supervisor. *)

val supervise_keepalive :
  publish_lifecycle:
    (event:Keeper_lifecycle_events.lifecycle_event ->
     string ->
     string ->
     unit ->
     unit) ->
  launch_supervised_fiber:
    ('a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     Keeper_registry.registry_entry ->
     (unit, Keeper_state_machine.transition_error) result) ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit
(** Register or launch an [Offline] supervised keepalive fiber only when the
    shared closed owner-execution verdict is [Recoverable]. Other registered
    phases remain owned by the lifecycle sweep. [Executable] is a no-op;
    lifecycle/policy blocks, unreadable owner truth, and a shutdown fence retain
    durable work without booting.
    When the injected launch gate returns [Error _] (registry FSM rejected
    [Fiber_started]), no [Started]/[Running] event is published — the gate
    already resolved the entry through the crash path. *)
