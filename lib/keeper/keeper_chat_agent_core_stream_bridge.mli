(** Translate AGENT_CORE typed stream events into keeper chat events.

    MASC owns the channel event surface, but the upstream stream semantics come
    from AGENT_CORE' closed {!Agent_core.Types.sse_event} sum. This module is the
    boundary adapter between those two domains.

    Text deltas are additionally reconciled against the per-block accumulated
    text (exact byte-length/prefix identity, never similarity): cumulative
    snapshot chunks are forwarded as their unseen suffix only, and exact
    retransmissions are dropped, so a duplicated provider chunk never renders
    twice.  Dedup occurrences bump
    [masc_keeper_stream_text_delta_dedup_total]. *)

type state
(** Per-stream correlation state for AGENT_CORE content block indices. *)

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}
(** Result of translating one typed AGENT_CORE stream event. *)

val empty_state : unit -> state
(** Reads the generated-media wire cap once, so every decision in this stream
    is made against one number even if an operator edits the env var while it
    runs. *)

val terminal_message_had_text : state -> bool
(** [true] when the last completed provider message (or the currently open
    message) emitted a non-empty text delta. Earlier tool-loop messages never
    affect this projection. *)

val translate :
  redact_text:(string -> string) ->
  base_dir:string ->
  state ->
  Agent_core.Types.sse_event ->
  translated_event
(** [base_dir] is the workspace base path used to persist RFC-0301 model-generated
    media (via {!Keeper_chat_media_store}) when a media block completes. *)
