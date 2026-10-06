(** Provider admission waits as MASC events.

    [Llm_provider.Provider_admission] reports each request that found every
    permit of its account held and queued. {!install} turns each report into
    one [masc.provider_admission.waited] event on the MASC bus; the relay
    writes it to [agent-core-events] and the dashboard SSE stream. A request
    granted a permit at once is not reported, so the events are exactly the
    requests that met a full account. *)

val wire_name : string

val event : Llm_provider.Provider_admission.wait -> Agent_core.Event_bus.event
(** Payload: [provider_id] (string or null), [kind], [model],
    [admission_class] (["priority"] or ["standard"]), [waited_ms] (number or
    null when no clock could measure it) and [outcome] (["granted"] or
    ["expired"]). *)

val install : sw:Eio.Switch.t -> Agent_core.Event_bus.t -> unit
(** Publish every reported wait to the bus until [sw] is released, when the
    observer is removed. Publishing only enqueues on the subscribers' queues,
    so it does not hold up the request that reports. *)
