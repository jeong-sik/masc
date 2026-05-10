(** Keeper_telemetry_consumer — MASC-side subscriber for OAS telemetry events.

    Subscribes to the OAS event bus via [Agent_sdk_metrics_bridge],
    filters [Custom("telemetry_event", json)] payloads, deserialises
    them with [Agent_sdk.Telemetry_event.of_yojson], and feeds the
    result into [Keeper_provider_health.update_from_event].

    A dedicated fiber drains the subscription in a loop.  If JSON
    deserialisation fails, the event is dropped and a Prometheus
    counter is bumped so operators can detect schema drift.

    State is purely internal: the subscription handle and the fiber
    are both bound to the caller's [Eio.Switch.t]. *)

let telemetry_event_counter = "masc_keeper_telemetry_events_consumed_total"
let telemetry_event_drop_counter = "masc_keeper_telemetry_events_dropped_total"

let spawn_subscriber ~sw ~bus =
  let sub =
    Agent_sdk_metrics_bridge.subscribe
      ~purpose:"telemetry_consumer"
      ~filter:(fun (evt : Agent_sdk.Event_bus.event) ->
        match evt.payload with
        | Agent_sdk.Event_bus.Custom ("telemetry_event", _) -> true
        | _ -> false)
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
              | Agent_sdk.Event_bus.Custom ("telemetry_event", json) -> (
                  match Agent_sdk.Telemetry_event.of_yojson json with
                  | Ok te ->
                      Keeper_provider_health.update_from_event te;
                      Prometheus.inc_counter
                        telemetry_event_counter
                        ~labels:[ "result", "ok" ]
                        ()
                  | Error err ->
                      Prometheus.inc_counter
                        telemetry_event_drop_counter
                        ~labels:[ "result", "deser_failed" ]
                        ();
                      Log.Keeper.debug
                        "telemetry_consumer: drop malformed event: %s"
                        err)
              | _ -> ())
           events
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Keeper.warn
             "telemetry_consumer: drain iteration failed: %s"
             (Printexc.to_string exn));
      loop ()
    in
    loop ())
