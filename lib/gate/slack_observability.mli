(** Slack connector observability helpers (RFC-0317).

    The outcome vocabularies and their labels come from
    {!Gate_connector_observability}, shared with the Discord connector — the
    counters differ, the [outcome] values do not. Only the gateway event
    vocabulary is Slack's own. Closed sums so a new event/outcome forces a
    label decision at compile time.

    The [struct include] form is what carries the type equations out; without
    it this signature would re-declare the variants and seal them, so
    [Slack_observability.Reply_sent] would stop being the shared
    constructor. *)

include module type of struct
  include Gate_connector_observability
end

type gateway_event =
  | Hello
  | Message_create
  | App_mention
  | Reaction_added
  | Ignored

val gateway_event_label : gateway_event -> string

val record_gateway_event : route:gateway_route -> gateway_event -> unit
(** Increment [masc_slack_gateway_events_total] with [event] and [route]
    labels. *)

val record_inbound_dispatch : inbound_outcome -> unit
(** Increment [masc_slack_inbound_dispatch_total] with an [outcome] label for a
    triggered inbound message after keeper binding lookup. *)

val record_ambient : ambient_outcome -> unit
(** Increment [masc_slack_ambient_record_total] with an [outcome] label for a
    record-only ambient message after keeper binding lookup (RFC-0226 parity
    with the Discord gateway). *)

val record_reply : reply_outcome -> unit
(** Increment [masc_slack_outbound_replies_total] with an [outcome] label for a
    reply send/edit attempt. *)
