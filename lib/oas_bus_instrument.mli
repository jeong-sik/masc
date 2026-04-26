(** MASC-side instrumentation wrapper around [Agent_sdk.Event_bus].

    Measures backpressure for OAS Event_bus usage: the OAS bus uses
    bounded [Eio.Stream]s per subscriber (buffer size 256). If a
    subscriber's drain loop falls behind, [Event_bus.publish] blocks
    on [Eio.Stream.add] and keeper turns hang silently. This module
    exposes three signals:

    - [masc_oas_bus_publish_block_seconds_total] — cumulative seconds
      spent inside [publish]. A ramp indicates a blocked/slow subscriber.
    - [masc_oas_bus_subscriber_stream_depth{subscriber_purpose=...}]
      — an indirect per-subscriber depth estimate. OAS does not
      expose [Eio.Stream.length] on its [subscription] type, so we
      track [publishes_matching_filter - events_drained] MASC-side
      for subscriptions created through this module. Publishes
      routed through [publish] below update every registered
      subscription's counter whose filter accepts the event.
    - A periodic sampler fiber that emits a WARN when depth crosses
      80% of the default OAS buffer (>200 / 256), then stays quiet
      until the subscriber recovers below the threshold.

    Subscriptions created directly via [Agent_sdk.Event_bus.subscribe]
    are invisible to this module. Use [subscribe] below for any MASC
    subscriber whose backpressure matters.

    @since 0.9.5 *)

(** A tracked subscription handle. Wraps the raw OAS subscription and
    carries the purpose label used for the gauge. *)
type handle

(** Subscribe to [bus] and register the subscription for depth
    tracking under [purpose]. [purpose] is the label value on the
    [masc_oas_bus_subscriber_stream_depth] gauge; keep it a short
    snake_case identifier (e.g. ["sse_bridge"], ["keeper_turn"],
    ["compact_audit"], ["lifecycle_listener"]). *)
val subscribe
  :  purpose:string
  -> ?filter:Agent_sdk.Event_bus.filter
  -> Agent_sdk.Event_bus.t
  -> handle

(** Drain the underlying subscription. Decrements the depth counter
    by the number of events returned and updates the gauge. *)
val drain : handle -> Agent_sdk.Event_bus.event list

(** Unsubscribe from [bus] and remove tracking state. *)
val unsubscribe : Agent_sdk.Event_bus.t -> handle -> unit

(** Publish [evt] via the OAS bus. Times the call for the
    [masc_oas_bus_publish_block_seconds_total] counter and, for every
    tracked subscription whose filter accepts [evt], increments the
    per-purpose depth counter. Exceptions propagate unchanged. *)
val publish : Agent_sdk.Event_bus.t -> Agent_sdk.Event_bus.event -> unit

(** Spawn the periodic depth sampler fiber. Reads the per-purpose
    depth counters every [~interval_s] seconds and emits a WARN log
    when any crosses above [~warn_threshold] (default 200, i.e. ~80%
    of the OAS default buffer size of 256), then an INFO when that
    subscriber recovers below the threshold. Safe to call once per
    server bootstrap; multiple calls spawn independent fibers (don't). *)
val start_sampler
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> ?interval_s:float
  -> ?warn_threshold:int
  -> unit
  -> unit

(** Test helpers. *)
module For_testing : sig
  type transition =
    [ `Warn of string * int
    | `Recovered of string * int
    ]

  val current_depth : purpose:string -> int
  val sample_threshold_transitions : warn_threshold:int -> transition list
  val reset : unit -> unit
end
