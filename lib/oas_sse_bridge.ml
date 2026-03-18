(** OAS Event_bus → SSE Bridge.

    Subscribes to all [masc:*] events on the OAS Event_bus
    and relays them as SSE broadcasts to connected dashboard clients.
    Pattern: gardener.ml [start_sentinel_reactor_fiber].

    @since 2.96.0 *)

(** Drain interval: how often we poll the Event_bus subscription. *)
let drain_interval_s = 2.0

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
      (try Sse.broadcast sse_json
       with exn ->
         Log.Server.error "oas_sse_bridge: broadcast failed: %s"
           (Printexc.to_string exn))
  | _ -> ()

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~bus =
  let sub = Agent_sdk.Event_bus.subscribe bus
    ~filter:(function
      | Agent_sdk.Event_bus.Custom (name, _) ->
          String.length name >= masc_prefix_len &&
          String.sub name 0 masc_prefix_len = masc_prefix
      | _ -> false)
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock drain_interval_s;
      let events = Agent_sdk.Event_bus.drain sub in
      List.iter relay_event events;
      loop ()
    in
    loop ())
