(** Keeper_telemetry_consumer — MASC-side observer for AGENT_CORE telemetry events.

    Subscribes to the AGENT_CORE event bus via [Runtime_event_bus],
    filters [Custom("telemetry_event", json)] payloads, and increments
    an OTel counter for dashboard visibility.

    Payloads are intentionally not persisted here: the same bus is fully
    persisted by {!Keeper_event_bridge} into [.masc/agent-core-events/] (the
    store {!Telemetry_unified} actually reads), so a second write-only
    copy under [data/harness-telemetry/] was removed (2026-07-20).

    MASC deliberately does not deserialize provider/model-bearing AGENT_CORE
    telemetry; concrete runtime identity belongs to AGENT_CORE.

    State is purely internal: the subscription handle and the fiber are
    bound to the caller's [Eio.Switch.t]. *)

let telemetry_event_counter = "masc_keeper_telemetry_events_consumed_total"

(* Drain is non-blocking; the loop must yield or it pins the Eio domain and
   starves co-located fibers (HTTP handlers, lazy startup tasks). *)
let drain_interval_s = 0.1

let spawn_subscriber ~sw ~clock ~bus =
  let sub =
    Runtime_event_bus.subscribe
      ~capacity:256
      ~overflow:Agent_core.Event_bus.Drop_oldest
      ~purpose:"telemetry_consumer"
      ~filter:(Agent_core.Event_bus.filter_topic "telemetry_event")
      bus
  in
  Eio.Switch.on_release sw (fun () ->
    Runtime_event_bus.unsubscribe bus sub);
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Runtime_event_bus.drain sub in
         List.iter
           (fun (evt : Agent_core.Event_bus.event) ->
              match evt.payload with
              | Agent_core.Event_bus.Custom ("telemetry_event", _json) ->
                  Otel_metric_store.inc_counter
                    telemetry_event_counter
                    ~labels:[ "result", "observed" ]
                    ()
              | _ -> ())
           events
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn
             "telemetry_consumer: drain iteration failed: %s"
             (Printexc.to_string exn));
      Eio.Time.sleep clock drain_interval_s;
      loop ()
    in
    loop ())
