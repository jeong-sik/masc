(** SSE event, freshness, chat stream chunk, and stream-gap reducer.

    Strictly preserves Channel 3 isolation: stream gaps, undecodable frames,
    and historical agent failures are appended to {!Incidents} and never
    degrade Channel 2 live Keeper health. *)

open Masc_tui_core
open Masc_tui_protocol

val apply_sse_event :
  now:Clock.Mono.t -> Model.t -> Msg.sse_event -> Model.t * Cmd.t list

val apply_sse_freshness :
  now:Clock.Mono.t ->
  stream:Subscriptions.stream_id ->
  freshness:Health.source_freshness ->
  Model.t ->
  Model.t * Cmd.t list

val apply_chat_stream_chunk :
  now:Clock.Mono.t ->
  keeper:string ->
  request_id:string ->
  is_btw:bool ->
  chunk:Wire_fleet.chat_stream_chunk ->
  Model.t ->
  Model.t * Cmd.t list

val apply_chat_stream_done :
  now:Clock.Mono.t ->
  keeper:string ->
  request_id:string ->
  is_btw:bool ->
  result:(unit, Msg.http_error) result ->
  Model.t ->
  Model.t * Cmd.t list

val apply_stream_gap :
  now:Clock.Mono.t -> int -> Model.t -> Model.t * Cmd.t list
