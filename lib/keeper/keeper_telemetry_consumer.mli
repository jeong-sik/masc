(** MASC-side observer for OAS telemetry events.

    Spawns a fiber that drains [Custom("telemetry_event", json)]
    payloads from the OAS event bus without deserializing provider/model
    identity.  Each event is persisted to
    [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. *)

val spawn_subscriber
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> base_path:string
  -> bus:Agent_sdk.Event_bus.t
  -> unit
(** [spawn_subscriber ~sw ~clock ~base_path ~bus] forks a fiber that
    drains [Custom("telemetry_event", json)] payloads from [bus],
    persists each one to [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl],
    and increments an OTel counter.  The fiber yields every 100 ms so
    co-located fibers are not starved. *)
