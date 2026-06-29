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

val translate :
  redact_text:(string -> string) ->
  on_text_delta:(string -> string) ->
  state ->
  Agent_sdk.Types.sse_event ->
  translated_event
