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

val purge_disallowed_state :
  session:Rbac.auth_session -> Model.t -> Model.t
(** Purge cached slices, active modals, token-editor drafts, and overlays that
    [session] is not allowed to observe. *)

val apply_runtime_token_swap :
  now:Clock.Mono.t ->
  token:string option ->
  Model.t ->
  Model.t * Cmd.t list
(** Apply a runtime Bearer/PAT token rotation ([Some tok]) or clear ([None]):
    wipe the masked draft, bump [epoch], purge disallowed state, stop active
    SSE streams, update [Cmd_executor]'s bearer token, clear workspace guard,
    and trigger a fresh [/health] handshake without restarting the TUI. *)

val revert_runtime_token_to_default :
  now:Clock.Mono.t ->
  Model.t ->
  Model.t * Cmd.t list
(** Clear any runtime bearer override and reload the default file/env token
    ([$MASC_TOKEN] / [.masc/auth/admin.token]) with a fresh epoch bump,
    disallowed/personal state purge, SSE drain, and [/health] re-probe. *)

val apply_auth_session_transition :
  now:Clock.Mono.t ->
  next_session:Rbac.auth_session ->
  Model.t ->
  Model.t * Cmd.t list
(** Transition [model.auth_session] to [next_session], handling initial auth
    completion, [Nav.Auth_gate] entry on auth loss, and in-place privilege
    demotion / identity-switch cleanup (epoch bump, modal/editor teardown,
    restricted cache purge, and SSE stream resync). *)

val maybe_recheck_auth : now:Clock.Mono.t -> Model.t -> Model.t * Cmd.t list
(** Issue a throttled background session re-probe ([Get_dashboard_shell] in
    single-user mode or [Get_auth_whoami] in multi-account mode) after an
    unexpected 403/401 on an authenticated session. *)

val apply_http_reply :
  now:Clock.Mono.t -> Model.t -> Msg.http_reply -> Model.t * Cmd.t list
