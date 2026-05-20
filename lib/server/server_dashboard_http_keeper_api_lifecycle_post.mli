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

val refresh_keeper_execution_surfaces :
  config:Coord.config -> name:string -> string -> unit
(** Invalidate caches and patch execution-surface dependents after a keeper
    lifecycle transition. *)

val invalidate_keeper_execution_surfaces : config:Coord.config -> unit -> unit
(** Invalidate snapshot/projection/execution caches without per-keeper
    patching (used on wakeup/reset paths). *)
