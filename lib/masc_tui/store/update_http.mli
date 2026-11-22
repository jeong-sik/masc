(** HTTP reply reducer, Channel 3 HTTP incident isolation, and loop-free
    [409 workspace_mismatch] recovery. *)

open Masc_tui_core

val handle_workspace_mismatch :
  now:Clock.Mono.t ->
  expected:string option ->
  observed:string option ->
  message:string ->
  Model.t ->
  Model.t * Cmd.t list
(** Bump [model.epoch], record a Channel 3 incident, mark domains stale, drain
    old streams, and issue a single re-handshake [Get_health] without looping. *)

val record_http_incident :
  now:Clock.Mono.t ->
  source:Health.incident_source ->
  context:Say.t ->
  Msg.http_error ->
  Model.t ->
  Model.t * Cmd.t list
(** Route [Workspace_mismatch] to {!handle_workspace_mismatch} and record all
    other HTTP/transport/decode errors strictly in Channel 3 [incidents]
    without degrading Channel 2 live health. *)

val apply_http_reply :
  now:Clock.Mono.t -> Model.t -> Msg.http_reply -> Model.t * Cmd.t list
