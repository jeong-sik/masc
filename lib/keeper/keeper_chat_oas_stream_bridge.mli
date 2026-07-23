(** Translate OAS typed stream events into keeper chat events.

    MASC owns the channel event surface, but the upstream stream semantics come
    from OAS' closed {!Agent_sdk.Types.sse_event} sum. This module is the
    boundary adapter between those two domains. *)

type state
(** Per-stream correlation state for OAS content block indices. *)

type translated_event = {
  bridge_state : state;
  chat_events : Keeper_chat_events.keeper_chat_event list;
}
(** Result of translating one typed OAS stream event. *)

val empty_state : state

val terminal_message_had_text : state -> bool
(** [true] when the last completed provider message (or the currently open
    message) emitted a non-empty text delta. Earlier tool-loop messages never
    affect this projection. *)

val translate :
  redact_text:(string -> string) ->
  base_dir:string ->
  state ->
  Agent_sdk.Types.sse_event ->
  translated_event
(** [base_dir] is the workspace base path used to persist RFC-0301 model-generated
    media (via {!Keeper_chat_media_store}) when a media block completes. *)
