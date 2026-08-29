(** Lifecycle POST handler (boot/up/shutdown/reset/clear) for keeper dashboard
    API. *)

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Generic handler for boot / up / shutdown / reset / clear posts; the
    [action] parameter selects the keeper FSM event. Boot rejects an ordinary
    paused owner instead of implicitly resuming it, and wakes an already-live
    keeper instead of dispatching [masc_keeper_up]. Up skips both boot-only
    paths so the dispatch reaches [masc_keeper_up]'s own create-or-update
    contract: the body carries the TOML-level settings and a changed keeper is
    intentionally stopped and restarted by that contract. *)

val refresh_keeper_execution_surfaces :
  config:Workspace.config ->
  name:string ->
  Keeper_lifecycle_events.lifecycle_event ->
  unit
(** Invalidate caches and patch execution-surface dependents after a keeper
    lifecycle transition. *)

val invalidate_keeper_execution_surfaces : config:Workspace.config -> unit -> unit
(** Invalidate snapshot/projection/execution caches without per-keeper
    patching (used on wakeup/reset paths). *)

type lifecycle_outcome =
  | Succeeded
  | Already_live
  | Rejected of string
  | Dispatch_none
  | Persist_failed of string
(** Outcome of a lifecycle action. The failing variants carry the sentence the
    caller was given; the same value goes to the HTTP response, so the log and
    the response cannot drift. Three gates answer [Rejected] — operator-paused
    meta, a paused registry lane, and the dispatched tool's own error — and
    they are indistinguishable without the payload. *)

val lifecycle_log_line :
  action:string ->
  name:string ->
  actor:string ->
  duration_ms:int ->
  lifecycle_outcome ->
  Log.level * string
(** The severity and the single log line for one lifecycle outcome. Severity
    follows docs/spec/18-log-severity-taxonomy.md § 3.6. A carried reason is
    appended last as [reason=...] with newlines collapsed to spaces, so free
    text from a dispatched tool cannot split the record across lines. *)
