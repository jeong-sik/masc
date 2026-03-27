(** OAS Event_bus → SSE Bridge.

    Subscribes to all [masc:*] events on the OAS Event_bus
    and relays them as SSE broadcasts to connected dashboard clients.
    Pattern: keeper supervisor fiber.

    @since 2.96.0 *)

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Oas_sse.drain_interval_sec

(** Prefix for events we relay. *)
let masc_prefix = "masc:"
let masc_prefix_len = String.length masc_prefix

(** Relay a single Event_bus event to SSE. *)
let relay_event = function
  | Agent_sdk.Event_bus.Custom (name, payload) ->
      let sse_json = `Assoc [
        ("type", `String ("oas:" ^ name));
        ("payload", payload);
        ("ts_unix", `Float (Time_compat.now ()));
      ] in
      (try Sse.broadcast_to Coordinators sse_json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Server.error "oas_sse_bridge: broadcast failed: %s"
           (Printexc.to_string exn))
  | _ -> ()

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~bus =
  let interval_s = drain_interval_s () in
  let sub = Agent_sdk.Event_bus.subscribe bus
    ~filter:(function
      | Agent_sdk.Event_bus.Custom (name, _) ->
          String.length name >= masc_prefix_len &&
          String.sub name 0 masc_prefix_len = masc_prefix
      | _ -> false)
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      let events = Agent_sdk.Event_bus.drain sub in
      List.iter relay_event events;
      Eio.Time.sleep clock interval_s;
      loop ()
    in
    loop ())
