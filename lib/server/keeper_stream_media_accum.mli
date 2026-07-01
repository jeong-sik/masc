(** Keeper_stream_media_accum — RFC-0301 item 6.

    Accumulates model-generated media streamed during a keeper turn so the turn's
    persist path can record it as reload-visible chat blocks. Parallel to
    {!Keeper_stream_text_accum}: fed the same raw OAS stream events, it collects
    media payload per block index and finalizes each block at its content-block
    stop. {!Keeper_chat_oas_stream_bridge} surfaces the same media live over SSE;
    this captures it for durable chat persistence so a dashboard reload still shows
    the generated image/audio instead of only text. *)

type t

val create : unit -> t

val on_event : t -> Agent_sdk.Types.sse_event -> unit
(** Feed one raw OAS stream event. Media deltas accumulate per block index; a
    content-block stop finalizes that index's media. Non-media events are ignored,
    so this can be called on every stream event unconditionally. *)

val to_chat_blocks : base_dir:string -> t -> Keeper_chat_blocks.chat_block list
(** Persist each finalized media payload under [base_dir] (content-addressed via
    {!Keeper_chat_media_store.persist}, so idempotent with the bridge's live
    persist — identical bytes reuse one file) and return the reload chat blocks in
    completion order: [Image] for image media, [Voice] for audio, [Attach] for
    documents / unrecognized types. Nothing is dropped. *)
