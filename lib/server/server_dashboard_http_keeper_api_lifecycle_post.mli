(** Lifecycle POST handler (boot/shutdown/reset/clear) for keeper dashboard API. *)

val handle_keeper_lifecycle_post :
  ?body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Generic handler for boot / shutdown / reset / clear posts; the [action]
    parameter selects the keeper FSM event. Boot rejects an ordinary paused
    owner instead of implicitly resuming it. *)

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

val handle_keeper_tool_post :
  body_str:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Time.clock ->
  tool_name:string ->
  action:String.t ->
  Mcp_server.server_state ->
  string -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Create-or-update ([up]) and force-compaction ([compact]) posts. The body
    is the workspace tool's own arguments minus [name]; the tool owns
    validation and the store transition, the route owns who it names. *)
