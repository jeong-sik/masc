(** MASC-side observer for OAS telemetry events.

    Spawns a fiber that drains [Custom("telemetry_event", json)]
    payloads from the OAS event bus without deserializing provider/model
    identity, incrementing an OTel counter per event. Payloads are not
    persisted here — the same bus is fully persisted by
    {!Keeper_event_bridge} into [.masc/oas-events/]. *)

val spawn_subscriber
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> bus:Agent_sdk.Event_bus.t
  -> unit
(** [spawn_subscriber ~sw ~clock ~bus] forks a fiber that drains
    [Custom("telemetry_event", json)] payloads from [bus] and increments
    an OTel counter for each. The fiber yields every 100 ms so
    co-located fibers are not starved. *)
