(** SSE broadcast helper for keeper chat persistence events.

    Pure side-effect wrapper — no chat store state read or written.
    Mirrors [Keeper_registry_broadcast] for lifecycle events. *)

(** Broadcast a [keeper_chat_appended] SSE event after a transcript-visible
    row is committed to its authoritative store. The two stores of
    transcript rows call it from their own writers: {!Keeper_chat_store}
    for the chat JSONL and the TurnRecord writer for autonomous turns, so a
    row reaches an open transcript whichever caller stored it. The event
    says a row is in; readers fetch the transcript to see it.

    [connector] is the row's surface lane label, absent when the row has
    no surface. [audio] is the row's synthesized clip (RFC-0235 P1); the
    dashboard decodes it into a typed record at the SSE edge and attaches
    a play button.

    The event has no dashboard slice mapping on purpose: slice-less
    events take the WS raw-forward catch-all to every authenticated
    session, which is the right cost profile for low-frequency chat
    turns.

    Exceptions from [Sse.broadcast] are counted on the
    [keeper_sse_broadcast_failures] counter (site [chat_appended]) and
    logged at WARN. {!Eio.Cancel.Cancelled} propagates. *)
val chat_appended :
  keeper_name:string ->
  ?connector:string ->
  ?audio:Keeper_chat_types.audio_clip ->
  unit ->
  unit


val operation_event_to_json :
  keeper_name:string ->
  operation_id:string ->
  seq:int option ->
  event:Ag_ui.event ->
  Yojson.Safe.t

(** Publish only to observers of [base_path]'s canonical runtime authority,
    including external transports and reconnect replay. The root is delivery
    authority, not a field inferred from the event's JSON payload. *)
val operation_event :
  base_path:string ->
  keeper_name:string ->
  operation_id:string ->
  seq:int option ->
  event:Ag_ui.event ->
  unit
