(** Keeper_telemetry_consumer — MASC-side observer for OAS telemetry events.

    Subscribes to the OAS event bus via [Agent_sdk_metrics_bridge],
    filters [Custom("telemetry_event", json)] payloads, and persists each
    event to [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}.

    Also increments a Prometheus counter so dashboards can show ingestion
    volume without scraping the JSONL store. *)

val spawn_subscriber
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> base_path:string
  -> bus:Agent_sdk.Event_bus.t
  -> unit
(** [spawn_subscriber ~sw ~clock ~base_path ~bus] forks a fiber that
    drains [Custom("telemetry_event", json)] payloads from [bus] and
    writes each one to [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl].
    The fiber yields every 100 ms so co-located fibers are not starved. *)