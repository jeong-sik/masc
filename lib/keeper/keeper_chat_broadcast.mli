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

(** Broadcast a [keeper_chat_appended] SSE event after a completed turn
    is persisted to the keeper's chat JSONL. The dashboard uses it to
    re-merge the server transcript live, so messages arriving through
    other connectors (Discord, Slack, agent MCP) appear without a page
    reload.

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

(** Broadcast a [keeper_chat_queue_changed] SSE event whenever a keeper's
    still-queued (not leased) message count changes: enqueue, lease, ack, or
    nack. [depth] is the count {!Keeper_chat_queue.length} would report right
    after the mutation. The busy-ack HTTP response already carries a
    one-shot [queue_length] at enqueue time (RFC-connector-deferred-reply-via-chat-queue); this event is
    what keeps that number live for a dashboard session that is already
    open and watching a keeper it did not just send a message to.

    Same failure contract as {!chat_appended}: exceptions from
    [Sse.broadcast] are counted and logged at WARN, {!Eio.Cancel.Cancelled}
    propagates. *)
val queue_changed : keeper_name:string -> depth:int -> unit -> unit
