(** Slack connector observability helpers (RFC-0317).

    Mirrors {!Discord_observability} for the Slack in-process gateway. Only the
    subset the server-side gateway emits directly is covered: gateway event
    flow, triggered-inbound dispatch outcomes, and outbound reply outcomes.
    Connection-level counters (reconnect/close) live in the I/O layer and are
    added when {!Slack_socket_client} grows observability. *)

include Gate_connector_observability

type gateway_event =
  | Hello
  | Message_create
  | App_mention
  | Reaction_added
  | Ignored

let gateway_event_label = function
  | Hello -> "hello"
  | Message_create -> "message_create"
  | App_mention -> "app_mention"
  | Reaction_added -> "reaction_added"
  | Ignored -> "ignored"

let inc name ~labels =
  Otel_metric_store_core.inc_counter name ~labels ()

let record_gateway_event ~route event =
  inc
    Otel_transport_metric_names.metric_slack_gateway_events
    ~labels:
      [ "event", gateway_event_label event
      ; "route", gateway_route_label route
      ]

let record_inbound_dispatch outcome =
  inc
    Otel_transport_metric_names.metric_slack_inbound_dispatch
    ~labels:[ "outcome", inbound_outcome_label outcome ]

let record_ambient outcome =
  inc
    Otel_transport_metric_names.metric_slack_ambient_record
    ~labels:[ "outcome", ambient_outcome_label outcome ]

let record_reply outcome =
  inc
    Otel_transport_metric_names.metric_slack_outbound_replies
    ~labels:[ "outcome", reply_outcome_label outcome ]
