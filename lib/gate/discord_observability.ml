(** Discord connector observability helpers. *)

include Gate_connector_observability

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

let gateway_event_label = function
  | Ready -> "ready"
  | Message_create -> "message_create"
  | Reaction_add -> "reaction_add"
  | Ignored -> "ignored"
  | Open_wss -> "open_wss"

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
