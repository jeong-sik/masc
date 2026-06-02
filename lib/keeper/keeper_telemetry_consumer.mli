(** MASC-side observer for OAS telemetry events.

    Spawns a fiber that drains [Custom("telemetry_event", json)]
    payloads from the OAS event bus without deserializing provider/model
    identity. *)

val spawn_subscriber
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> bus:Agent_sdk.Event_bus.t
  -> unit
