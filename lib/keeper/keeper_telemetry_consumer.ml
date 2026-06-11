(** Keeper_telemetry_consumer — MASC-side observer for OAS telemetry events.

    Subscribes to the OAS event bus via [Agent_sdk_metrics_bridge],
    filters [Custom(\"telemetry_event\", json)] payloads, and persists each
    event to a dated JSONL store under [<base_path>/telemetry_events/].
    MASC deliberately does not deserialize provider/model-bearing OAS
    telemetry; concrete runtime identity belongs to OAS.

    State is purely internal: the subscription handle, the fiber, and the
    Dated_jsonl store are all bound to the caller's [Eio.Switch.t]. *)

let telemetry_event_counter = "masc_keeper_telemetry_events_consumed_total"

(* drain is non-blocking; loop must yield or it pins the Eio domain and
   starves co-located fibers (HTTP handlers, lazy startup tasks). *)
let drain_interval_s = 0.1

let store_base_dir base_path = Filename.concat base_path "telemetry_events"

let store_ref : Dated_jsonl.t option ref = ref None

let get_store base_path =
  match !store_ref with
  | Some s -> s
  | None ->
      let s =
        Dated_jsonl.create ~base_dir:(store_base_dir base_path) ()
      in
      store_ref := Some s;
      s

let spawn_subscriber ~sw ~clock ~bus ~base_path =
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
  (* Initialise the store now so creation error surfaces during setup. *)
  let _store = get_store base_path in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk_metrics_bridge.drain sub in
         List.iter
           (fun (evt : Agent_sdk.Event_bus.event) ->
              match evt.payload with
              | Agent_sdk.Event_bus.Custom ("telemetry_event", json) ->
                  Otel_metric_store.inc_counter
                    telemetry_event_counter
                    ~labels:[ "result", "observed" ]
                    ();
                  (* Persist the raw JSON payload — OAS owns schema. *)
                  Dated_jsonl.append (get_store base_path) json
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