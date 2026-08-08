(** Bridge Durable_event journal events to Event_bus.

    Each journal event is projected onto {!Event_bus.Custom} with a
    stable [durable.<kind>] name (e.g. [durable.turn_started],
    [durable.llm_request]).  Subscribers observe these via the normal
    Event_bus subscription — no payload schema change required.

    @since 0.133.0
    @since 0.154.0 naming normalized to dot convention; [?correlation_id]
    and [?run_id] threaded through so bridged events share an envelope
    with the surrounding agent run. *)

(** Serialize a journal event into the [(name, payload)] shape used by
    {!Event_bus.Custom}.  Exposed for testing and custom relays. *)
val projection_of_event : Durable_event.event -> string * Yojson.Safe.t

(** Build an [on_append] callback suitable for {!Durable_event.create}
    that publishes every journal event to [bus] as an
    {!Event_bus.Custom} payload.

    If [?correlation_id] / [?run_id] are supplied, every projected event
    is published with that envelope so it joins the same trace as the
    surrounding agent run.  If omitted, each event gets a fresh
    envelope, which is fine for standalone journals but breaks
    correlation-based querying in multi-agent sessions.

    The callback does not absorb publication failures. When installed as
    {!Durable_event.create}'s [on_append], the journal event is already
    committed: ordinary publication exceptions are returned by
    {!Durable_event.append}, while reserved runtime exceptions and cancellation
    propagate with their original backtrace. *)
val make
  :  bus:Event_bus.t
  -> ?correlation_id:string
  -> ?run_id:string
  -> unit
  -> Durable_event.event
  -> unit
