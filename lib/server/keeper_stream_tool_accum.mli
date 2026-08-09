(** Turn-local collector for the tool calls a keeper made during one chat
    stream, so the persisted turn keeps them and a reload still shows the tool
    timeline.

    The chat stream already carries [ContentBlockStart] with a tool identity
    and [InputJsonDelta]/[InputJsonSnapshot] argument fragments, but the
    persist site had no way to read them: only generated media was collected
    ({!Keeper_stream_media_accum}), so [append_turn_result] was called without
    [?tool_calls] and history rows carried no tool rows at all. The live
    transcript therefore showed tool steps while the stream was open and lost
    them on reload.

    Mirrors the media collector's shape deliberately: a turn-local mutable
    accumulator fed the same raw events, kept separate from the SSE bridge so
    live translation and durable persistence stay on their own side of the
    AGENT_CORE-stream / chat-store boundary. *)

type t

val create : unit -> t

val on_event : t -> Agent_core.Types.sse_event -> unit
(** Feed one raw AGENT_CORE stream event. A tool-bearing [ContentBlockStart] opens a
    block, argument deltas append to it, and [ContentBlockStop] / [MessageStop]
    finalize. Snapshots replace the accumulated fragments rather than appending,
    matching the provider contract. A [MediaDelta] marks its index as
    media-occupied until the block's terminator, mirroring the SSE bridge which
    opens media blocks from a bare delta and rejects tool starts that collide
    with them; other non-tool events are ignored. *)

val to_tool_calls : t -> Keeper_chat_store.tool_call list
(** The tool calls finalized so far, in the order the provider opened them.
    A block whose identity never arrived is omitted: a tool row with no call id
    cannot be joined to its output and would render as an anonymous step. *)
