(** SSE broadcast helper for keeper chat persistence events.

    Pure side-effect wrapper — no chat store state read or written.
    Mirrors [Keeper_registry_broadcast] for lifecycle events. *)

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
val chat_appended : keeper_name:string -> source:string -> unit
