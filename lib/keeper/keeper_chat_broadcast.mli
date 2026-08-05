(** SSE broadcast helper for keeper chat persistence events.

    Pure side-effect wrapper — no chat store state read or written.
    Mirrors [Keeper_registry_broadcast] for lifecycle events. *)

(** Audio clip descriptor attached to a [keeper_chat_appended] event when
    the utterance was synthesized (RFC-0235 P1). See {!audio_clip} in the
    .ml for the full contract. *)
type audio_clip = {
  token : string;
  audio_url : string option;
  mime : string;
  duration_sec : float option;
  message_text : string;
  device_id : string option;
  expired : bool;
}

(** Broadcast a [keeper_chat_appended] SSE event after a transcript-visible
    row is committed to its authoritative store: the chat JSONL for direct
    messages, or the TurnRecord store for autonomous turns. The dashboard uses
    it to re-merge the server transcript live without a page reload.

    The event has no dashboard slice mapping on purpose: slice-less
    events take the WS raw-forward catch-all to every authenticated
    session, which is the right cost profile for low-frequency chat
    turns.

    Exceptions from [Sse.broadcast] are counted on the
    [keeper_sse_broadcast_failures] counter (site [chat_appended]) and
    logged at WARN. {!Eio.Cancel.Cancelled} propagates. *)
val chat_appended :
  keeper_name:string -> source:string -> ?content:string -> unit -> unit

(** Like {!chat_appended} but attaches a synthesized audio clip
    (RFC-0235 P1) so the dashboard can render a play button instead of
    relying on server-local playback. Only a turn that owns a voice clip
    ([Voice_bridge_transport.make_audio_file] token) calls this; every
    other caller keeps using {!chat_appended}. The [audio] field is
    decoded into a typed record at the SSE edge, never string-sniffed
    downstream. [content] is used to derive rich blocks for the event. *)
val chat_appended_with_audio :
  keeper_name:string -> source:string -> audio:audio_clip -> ?content:string -> unit -> unit

(** Kind of a [keeper_chat_turn_progress] event. *)
type turn_progress_kind =
  | Tool_call_started
  | Tool_call_ended

val turn_progress_kind_to_string : turn_progress_kind -> string

(** Serialize a [keeper_chat_turn_progress] event. Exposed for unit tests. *)
val turn_progress_to_json :
  keeper_name:string ->
  run_id:string ->
  kind:turn_progress_kind ->
  tool_call_id:string ->
  tool_name:string option ->
  receipt_ids:string list ->
  Yojson.Safe.t

(** Broadcast a [keeper_chat_turn_progress] SSE event when a turn executes a
    tool call, so dashboard clients watching a queued/consumer-side turn see
    live progress in the chat thread instead of a silent gap until
    {!chat_appended}. Slice-less like {!chat_appended}: it rides the WS
    raw-forward catch-all to every authenticated session, and the dashboard
    applies it idempotently keyed by [tool_call_id].

    [receipt_ids] carries the queue-lane producer identity for queued turns
    so the dashboard's history-convergence machinery can fold a live progress
    placeholder into the canonical transcript row at turn end.

    Carries tool identity only — never args or results — so no redaction is
    needed at this boundary. Exceptions from [Sse.broadcast] are counted on
    the [keeper_sse_broadcast_failures] counter (site [chat_turn_progress])
    and logged at WARN. {!Eio.Cancel.Cancelled} propagates. *)
val turn_progress :
  keeper_name:string ->
  run_id:string ->
  kind:turn_progress_kind ->
  tool_call_id:string ->
  ?tool_name:string ->
  ?receipt_ids:string list ->
  unit ->
  unit
