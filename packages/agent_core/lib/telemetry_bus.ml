(** Typed telemetry event bus — wraps {!Event_bus.t} with a
    {!Llm_provider.Telemetry_event.t}-typed API.

    Events are serialized to JSON and published as
    [Event_bus.Custom("telemetry_event", json)].  Subscribers that only
    want telemetry events can use [Event_bus.filter_topic "telemetry_event"]
    on the underlying bus; the typed API here handles the
    serialization round-trip automatically.

    @since 0.189.0 *)

type t = { bus : Event_bus.t }
type subscription = { inner : Event_bus.subscription }

type decode_failure =
  { event : Event_bus.event
  ; detail : string
  }

let create () = { bus = Event_bus.create () }
let of_event_bus bus = { bus }

(* ── Publish ──────────────────────────────────────────────────────── *)

let publish bus event =
  let json = Llm_provider.Telemetry_event.to_yojson event in
  let payload = Event_bus.Custom ("telemetry_event", json) in
  let ev = Event_bus.mk_event payload in
  Event_bus.publish bus.bus ev
;;

(* ── Subscribe ────────────────────────────────────────────────────── *)

let subscribe ~config ?purpose bus =
  let inner =
    Event_bus.subscribe
      ~config
      ~filter:(Event_bus.filter_topic "telemetry_event")
      ?purpose
      bus.bus
  in
  { inner }
;;

let unsubscribe bus sub = Event_bus.unsubscribe bus.bus sub.inner

(* ── Drain ────────────────────────────────────────────────────────── *)

let drain sub =
  Event_bus.drain sub.inner
  |> List.map (fun (ev : Event_bus.event) ->
    match ev.payload with
    | Event_bus.Custom ("telemetry_event", json) ->
      (match Llm_provider.Telemetry_event.of_yojson json with
       | Ok telemetry_event -> Ok telemetry_event
       | Error detail -> Error { event = ev; detail })
    | _ ->
      Error
        { event = ev; detail = "telemetry subscription received a non-telemetry payload" })
;;

(* ── Queries ──────────────────────────────────────────────────────── *)

let subscriber_count bus = Event_bus.subscriber_count bus.bus
let stats bus = Event_bus.stats bus.bus
