(** Says that a connector's state changed (RFC-0480 §3.4).

    The event is [{"type":"gate_connector_changed","connector":<id>,"ts_unix":...}]
    and goes to the observer sessions of [base_path]'s runtime only, not to
    external subscribers: an external callback may wait, and this runs under the
    writer's lock. A reader that shows connectors
    ([GET /api/v1/gate/connectors], [GET /api/v1/gate/connector/names]) reads
    that connector again.

    The server installs {!observer} into [Gate_connector_announce] at boot. The
    binding store and the connector name directory call it after their write,
    under their lock, so it must not yield and must not raise. An exception
    from the broadcast or from resolving the runtime, a [Cancelled] included,
    is counted on [keeper_sse_broadcast_failures] and logged at WARN. *)

val changed_event : string

val observer : base_path:string -> connector_id:string -> unit
