(** Lifecycle POST handler (boot/shutdown/reset/clear) for keeper dashboard API. *)

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Generic handler for boot / shutdown / reset / clear posts; the
    [action] parameter selects the keeper FSM event. *)

val handle_keeper_create_post :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
(** Handle [POST /api/v1/keepers/<name>/create] — REST surface over
    [masc_keeper_create_from_persona]. The path segment is the keeper
    name and wins over any [name] in the body; other body fields
    (persona_name, initial_goal, no_boot, dry_run, ...) pass through to
    the tool unchanged. *)

val refresh_keeper_execution_surfaces :
  config:Workspace.config -> name:string -> string -> unit
(** Invalidate caches and patch execution-surface dependents after a keeper
    lifecycle transition. *)

val invalidate_keeper_execution_surfaces : config:Workspace.config -> unit -> unit
(** Invalidate snapshot/projection/execution caches without per-keeper
    patching (used on wakeup/reset paths). *)
