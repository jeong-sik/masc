(** Typed telemetry event bus — wraps {!Event_bus.t} with a
    {!Llm_provider.Telemetry_event.t}-typed API.

    Events are serialized to JSON and published as
    [Event_bus.Custom("telemetry_event", json)].  Subscribers that only
    want telemetry events can use [Event_bus.filter_topic "telemetry_event"]
    on the underlying bus.

    @since 0.189.0 *)

type t = { bus : Event_bus.t }

let of_event_bus bus = { bus }

(* ── Publish ──────────────────────────────────────────────────────── *)

let publish bus event =
  let json = Llm_provider.Telemetry_event.to_yojson event in
  let payload = Event_bus.Custom ("telemetry_event", json) in
  let ev = Event_bus.mk_event payload in
  Event_bus.publish bus.bus ev
;;
