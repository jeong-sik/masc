(** Keeper_telemetry_consumer — MASC-side observer for OAS telemetry events.

    Subscribes to the OAS event bus via [Agent_sdk_metrics_bridge],
    filters [Custom("telemetry_event", json)] payloads, persists each
    event to [{base_path}/data/harness-telemetry/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}, and increments an OTel counter for dashboard
    visibility.

    MASC deliberately does not deserialize provider/model-bearing OAS
    telemetry; concrete runtime identity belongs to OAS.

    State is purely internal: the subscription handle, the fiber, and the
    {!Dated_jsonl.t} store are all bound to the caller's [Eio.Switch.t]. *)

let telemetry_event_counter = "masc_keeper_telemetry_events_consumed_total"

(* Drain is non-blocking; the loop must yield or it pins the Eio domain and
   starves co-located fibers (HTTP handlers, lazy startup tasks). *)
let drain_interval_s = 0.1

let spawn_subscriber ~sw ~clock ~base_path ~bus =
  let store =
    Dated_jsonl.create
      ~base_dir:(Filename.concat base_path "data/harness-telemetry")
      ()
  in
  let sub =
    Agent_sdk_metrics_bridge.subscribe
      ~contract:
        (Masc_event_bus_subscription.for_subscriber
           Masc_event_bus_subscription.Telemetry_consumer)
      ~filter:(Agent_sdk.Event_bus.filter_topic "telemetry_event")
      bus
  in
  Eio.Switch.on_release sw (fun () ->
    Agent_sdk_metrics_bridge.unsubscribe bus sub);
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk_metrics_bridge.drain sub in
         List.iter
           (fun (evt : Agent_sdk.Event_bus.event) ->
              match evt.payload with
              | Agent_sdk.Event_bus.Custom (_, json) ->
                  Otel_metric_store.inc_counter
                    telemetry_event_counter
                    ~labels:[ "result", "observed" ]
                    ();
                  Dated_jsonl.append store json
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
