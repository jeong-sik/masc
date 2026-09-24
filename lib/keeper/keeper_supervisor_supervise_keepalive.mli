(** Keepalive supervision entry point for the keeper supervisor. *)

module For_testing : sig
  val same_offline_generation :
    expected:Keeper_registry.registry_entry ->
    Keeper_registry.registry_entry ->
    bool
end

val supervise_keepalive :
  publish_lifecycle:
    (event:Keeper_lifecycle_events.lifecycle_event ->
     string ->
     string ->
     unit ->
     unit) ->
  launch_supervised_fiber:
    (intake_token:Keeper_shutdown_intake_fence.intake_token ->
     lifecycle_token:Keeper_lifecycle_reservation.token ->
     proactive_warmup_sec:int ->
     'a Keeper_types_profile.context ->
     Keeper_meta_contract.keeper_meta ->
     Keeper_registry.registry_entry ->
     (unit, Keeper_state_machine.transition_error) result) ->
  proactive_warmup_sec:int ->
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  unit
(** Register or launch an [Offline] supervised keepalive fiber only when the
    shared closed owner-execution verdict is [Recoverable]. Other registered
    phases remain owned by the lifecycle sweep. [Executable] is a no-op;
    lifecycle/policy blocks, unreadable owner truth, and a shutdown fence retain
    durable work without booting.
    A successful launch wakes the Owner's queued-operation drain before
    publishing [Started]/[Running].
    When the injected launch gate returns [Error _] (registry FSM rejected
    [Fiber_started]), no [Started]/[Running] event is published — the gate
    already resolved the entry through the crash path. *)
