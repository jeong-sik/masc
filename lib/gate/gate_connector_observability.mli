(** Outcome vocabularies every chat connector reports, and their metric
    labels.

    Slack and Discord write to different counters but tag them with the same
    [outcome] values. Keeping one declaration means adding a constructor
    breaks the label function once, for every connector, instead of leaving
    the second one to be noticed by hand. What stays per-connector is what
    genuinely differs: the gateway event vocabulary, and Discord's reconnect
    types.

    Closed sums so a new outcome forces a label decision at compile time.

    Both connectors re-export this module, so [Slack_observability.Reply_sent]
    and [Discord_observability.Reply_sent] name the same constructor of the
    same type. *)

type gateway_route =
  | Control
  | Triggered
  | Ambient

type inbound_outcome =
  | Dropped_unbound
  | Dispatch_unavailable
  | Gate_error
  | Empty_reply
  | Reply_sent
  | Reply_send_error

type ambient_outcome =
  | Ambient_recorded
  | Ambient_binding_store_error
  | Ambient_dropped_unbound
  | Ambient_dropped_empty
  | Ambient_dropped_too_long

type reply_outcome =
  | Reply_empty
  | Reply_send_ok
  | Reply_send_failed

val gateway_route_label : gateway_route -> string
val inbound_outcome_label : inbound_outcome -> string
val ambient_outcome_label : ambient_outcome -> string
val reply_outcome_label : reply_outcome -> string
