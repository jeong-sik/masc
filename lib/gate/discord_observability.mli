(** Discord connector observability helpers.

    Metric labels are intentionally low-cardinality: no channel, guild, user,
    message, or keeper identifiers are exported. Runtime identity stays in
    JSONL logs and connector status surfaces. *)

(** The outcome vocabularies and their labels come from
    {!Gate_connector_observability}, shared with the Slack connector — the
    counters differ, the [outcome] values do not. The gateway event vocabulary
    and the reconnect types are Discord's own.

    The [struct include] form is what carries the type equations out; without
    it this signature would re-declare the variants and seal them, so
    [Discord_observability.Reply_sent] would stop being the shared
    constructor. *)

include module type of struct
  include Gate_connector_observability
end

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

val gateway_event_label : gateway_event -> string
val record_gateway_event : route:gateway_route -> gateway_event -> unit
val record_gateway_close : code:int -> unit
val record_gateway_reconnect_scheduled : unit -> unit
val record_gateway_ack_timeout : unit -> unit
val record_gateway_reconnect_outcome :
  method_:reconnect_method -> outcome:reconnect_outcome -> unit
val record_inbound_dispatch : inbound_outcome -> unit
val record_ambient : ambient_outcome -> unit
val record_reply : reply_outcome -> unit
