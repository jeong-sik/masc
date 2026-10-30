(** Outcome vocabularies every chat connector reports, and their metric
    labels.

    Slack and Discord write to different counters but tag them with the same
    [outcome] values. Keeping one declaration means adding a constructor
    breaks the label function once, for every connector, instead of leaving
    the second one to be noticed by hand. What stays per-connector is what
    genuinely differs: the gateway event vocabulary, and Discord's reconnect
    types.

    Closed sums so a new outcome forces a label decision at compile time. *)

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

let gateway_route_label = function
  | Control -> "control"
  | Triggered -> "triggered"
  | Ambient -> "ambient"

let inbound_outcome_label = function
  | Dropped_unbound -> "dropped_unbound"
  | Dispatch_unavailable -> "dispatch_unavailable"
  | Gate_error -> "gate_error"
  | Empty_reply -> "empty_reply"
  | Reply_sent -> "reply_sent"
  | Reply_send_error -> "reply_send_error"

let ambient_outcome_label = function
  | Ambient_recorded -> "recorded"
  | Ambient_binding_store_error -> "binding_store_error"
  | Ambient_dropped_unbound -> "dropped_unbound"
  | Ambient_dropped_empty -> "dropped_empty"
  | Ambient_dropped_too_long -> "dropped_too_long"

let reply_outcome_label = function
  | Reply_empty -> "empty"
  | Reply_send_ok -> "sent"
  | Reply_send_failed -> "send_error"
