(** MASC-side subscriber for OAS telemetry events.

    Spawns a fiber that drains [Custom("telemetry_event", json)]
    payloads from the OAS event bus and feeds them into
    [Keeper_provider_health]. *)

val spawn_subscriber
  :  sw:Eio.Switch.t
  -> bus:Agent_sdk.Event_bus.t
  -> unit
