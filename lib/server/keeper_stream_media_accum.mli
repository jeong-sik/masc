(** Keeper_stream_media_accum — RFC-0301 item 6.

    Accumulates model-generated media streamed during a keeper turn so the turn's
    persist path can record it as reload-visible chat blocks. Parallel to
    {!Keeper_stream_text_accum}: fed the same raw OAS stream events, it mirrors the
    bridge's media validity rules for durable reload persistence. It collects media
    payload per block index, rejects media deltas for tool/invalid blocks, preserves
    the first media metadata for an active block, and finalizes at either
    [ContentBlockStop] or [MessageStop]. {!Keeper_chat_oas_stream_bridge} surfaces
    the same media live over SSE; this captures it for durable chat persistence so
    a dashboard reload still shows the generated image/audio instead of only text. *)

type t

val create : unit -> t

val on_event : t -> Agent_sdk.Types.sse_event -> unit
(** Feed one raw OAS stream event. Media deltas accumulate per block index;
    [ContentBlockStop] finalizes one index and [MessageStop] finalizes all still
    open media. Non-media events are ignored except tool starts, which mark their
    index invalid for media persistence. *)

val to_chat_blocks : base_dir:string -> t -> Keeper_chat_blocks.chat_block list
(** Decode and persist each finalized media payload under [base_dir] via
    {!Keeper_chat_media_store.persist_media_source_result}, then return reload
    chat blocks in completion order: [Image] for image media, [Voice] for audio,
    [Attach] for documents / unrecognized types. *)
