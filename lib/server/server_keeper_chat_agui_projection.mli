(** Pure projection from the channel-neutral Keeper chat event stream to the
    AG-UI wire event consumed by Dashboard clients. *)

type t

val initial : t

(** [project] advances the immutable stream identity carried by lifecycle
    events and returns the corresponding AG-UI event, when the source event is
    visible on the Dashboard surface. Connector-only rich blocks project to
    [None]. *)
val project :
  timestamp:float ->
  redact_text:(string -> string) ->
  redact_json:(Yojson.Safe.t -> Yojson.Safe.t) ->
  t ->
  Keeper_chat_events.keeper_chat_event ->
  t * Ag_ui.event option

val is_terminal : Keeper_chat_events.keeper_chat_event -> bool
