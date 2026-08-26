(** Translate AGENT_CORE typed stream events into keeper chat events.

    MASC owns the channel event surface, but the upstream stream semantics come
    from AGENT_CORE' closed {!Agent_core.Types.sse_event} sum. This module is the
    boundary adapter between those two domains.

    Text deltas arriving here are already canonical: the Agent Core stream
    state reduces explicitly typed [TextSnapshot] values to unseen suffixes and
    suppresses exact snapshot replays before invoking this boundary. Ordinary
    [TextDelta] values always append. This adapter projects each accepted delta
    exactly once and never reinterprets it. *)

type state
(** Per-stream correlation state for AGENT_CORE content block indices. *)

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}
(** Result of translating one typed AGENT_CORE stream event. *)

val empty_state : unit -> state

val start_runtime_attempt
  :  abandon_current_scope:bool
  -> state
  -> translated_event
(** Reset unfinished text/thinking state at an exact resolved-runtime attempt
    boundary. When [abandon_current_scope] is true, terminalize every tool
    occurrence in that unsealed scope as superseded. The durable tool
    accumulator computes this disposition before advancing, so a sealed or
    result-ready occurrence remains intact on both live and persisted surfaces. *)

val fail_stream : state -> reason:string -> translated_event
(** Quarantine every tool occurrence in the current provider scope when the
    outer transport/cancellation boundary fails after the typed stream reader
    can no longer emit another event. Idempotent after an earlier scope
    failure. *)
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
  stream_scope:int ->
  state ->
  Agent_core.Types.sse_event ->
  translated_event
(** [base_dir] is the workspace base path used to persist RFC-0301 model-generated
    media (via {!Keeper_chat_media_store}) when a media block completes. *)
