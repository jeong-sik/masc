(** Discord connector observability helpers.

    Metric labels are intentionally low-cardinality: no channel, guild, user,
    message, or keeper identifiers are exported. Runtime identity stays in
    JSONL logs and connector status surfaces. *)

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

val gateway_route_label : gateway_route -> string
val gateway_event_label : gateway_event -> string
val inbound_outcome_label : inbound_outcome -> string
val ambient_outcome_label : ambient_outcome -> string
val reply_outcome_label : reply_outcome -> string
val reconnect_method_label : reconnect_method -> string
val reconnect_outcome_label : reconnect_outcome -> string

val record_gateway_event : route:gateway_route -> gateway_event -> unit
val record_gateway_close : code:int -> unit
val record_gateway_reconnect_scheduled : unit -> unit
val record_gateway_ack_timeout : unit -> unit
val record_gateway_reconnect_outcome :
  method_:reconnect_method -> outcome:reconnect_outcome -> unit
val record_inbound_dispatch : inbound_outcome -> unit
val record_ambient : ambient_outcome -> unit
val record_reply : reply_outcome -> unit
