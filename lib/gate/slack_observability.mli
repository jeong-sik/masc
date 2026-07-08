(** Slack connector observability helpers (RFC-0317).

    Mirrors {!Discord_observability} for the Slack in-process gateway. Closed
    sums so a new event/outcome forces a label decision at compile time. *)

type gateway_route =
  | Control
  | Triggered
  | Ambient

type gateway_event =
  | Hello
  | Message_create
  | App_mention
  | Reaction_added
  | Ignored

type inbound_outcome =
  | Dropped_unbound
  | Dispatch_unavailable
  | Gate_error
  | Empty_reply
  | Reply_sent
  | Reply_send_error

type reply_outcome =
  | Reply_empty
  | Reply_send_ok
  | Reply_send_failed

val gateway_route_label : gateway_route -> string
val gateway_event_label : gateway_event -> string
val inbound_outcome_label : inbound_outcome -> string
val reply_outcome_label : reply_outcome -> string

val record_gateway_event : route:gateway_route -> gateway_event -> unit
(** Increment [masc_slack_gateway_events_total] with [event] and [route]
    labels. *)

val record_inbound_dispatch : inbound_outcome -> unit
(** Increment [masc_slack_inbound_dispatch_total] with an [outcome] label for a
    triggered inbound message after keeper binding lookup. *)

val record_reply : reply_outcome -> unit
(** Increment [masc_slack_outbound_replies_total] with an [outcome] label for a
    reply send/edit attempt. *)
