(** Discord connector observability helpers. *)

type gateway_route =
  | Control
  | Triggered
  | Ambient

type gateway_event =
  | Ready
  | Message_create
  | Reaction_add
  | Ignored
  | Open_wss

type reconnect_method =
  | Resume
  | Fresh_identify

type reconnect_outcome =
  | Reconnect_succeeded
  | Reconnect_failed

type inbound_outcome =
  | Dropped_unbound
  | Dispatch_unavailable
  | Gate_error
  | Empty_reply
  | Reply_sent
  | Reply_send_error

type ambient_outcome =
  | Ambient_recorded
  | Ambient_dropped_unbound
  | Ambient_dropped_empty

type reply_outcome =
  | Reply_empty
  | Reply_send_ok
  | Reply_send_failed

let gateway_route_label = function
  | Control -> "control"
  | Triggered -> "triggered"
  | Ambient -> "ambient"

let gateway_event_label = function
  | Ready -> "ready"
  | Message_create -> "message_create"
  | Reaction_add -> "reaction_add"
  | Ignored -> "ignored"
  | Open_wss -> "open_wss"

let inbound_outcome_label = function
  | Dropped_unbound -> "dropped_unbound"
  | Dispatch_unavailable -> "dispatch_unavailable"
  | Gate_error -> "gate_error"
  | Empty_reply -> "empty_reply"
  | Reply_sent -> "reply_sent"
  | Reply_send_error -> "reply_send_error"

let ambient_outcome_label = function
  | Ambient_recorded -> "recorded"
  | Ambient_dropped_unbound -> "dropped_unbound"
  | Ambient_dropped_empty -> "dropped_empty"

let reply_outcome_label = function
  | Reply_empty -> "empty"
  | Reply_send_ok -> "sent"
  | Reply_send_failed -> "send_error"

let reconnect_method_label = function
  | Resume -> "resume"
  | Fresh_identify -> "fresh_identify"

let reconnect_outcome_label = function
  | Reconnect_succeeded -> "succeeded"
  | Reconnect_failed -> "failed"

let inc name ~labels =
  Otel_metric_store_core.inc_counter name ~labels ()

let record_gateway_event ~route event =
  inc
    Otel_transport_metric_names.metric_discord_gateway_events
    ~labels:
      [ "event", gateway_event_label event
      ; "route", gateway_route_label route
      ]

let record_gateway_close ~code =
  inc
    Otel_transport_metric_names.metric_discord_gateway_closes
    ~labels:[ "code", string_of_int code ]

let record_gateway_reconnect_scheduled () =
  inc
    Otel_transport_metric_names.metric_discord_gateway_reconnect_scheduled
    ~labels:[]

let record_gateway_ack_timeout () =
  inc Otel_transport_metric_names.metric_discord_gateway_ack_timeouts ~labels:[]

let record_inbound_dispatch outcome =
  inc
    Otel_transport_metric_names.metric_discord_inbound_dispatch
    ~labels:[ "outcome", inbound_outcome_label outcome ]

let record_ambient outcome =
  inc
    Otel_transport_metric_names.metric_discord_ambient_record
    ~labels:[ "outcome", ambient_outcome_label outcome ]

let record_reply outcome =
  inc
    Otel_transport_metric_names.metric_discord_outbound_replies
    ~labels:[ "outcome", reply_outcome_label outcome ]

let record_gateway_reconnect_outcome ~method_ ~outcome =
  inc
    Otel_transport_metric_names.metric_discord_gateway_reconnect_outcomes
    ~labels:
      [ "method", reconnect_method_label method_
      ; "outcome", reconnect_outcome_label outcome
      ]
