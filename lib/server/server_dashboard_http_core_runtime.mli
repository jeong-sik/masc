(** Dashboard compute-runtime bindings extracted from
    {!Server_dashboard_http_core}. *)

val runtime_support : Server_dashboard_http_runtime_support.t
(** Shared runtime-support handle for dashboard compute dispatch. *)

val set_executor_pool : Eio.Executor_pool.t -> unit
(** Register the dashboard executor pool. *)

val dashboard_runtime :
  ?net:Eio_context.eio_net ->
  ?mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  Coord.config ->
  Server_dashboard_http_runtime_support.runtime option
(** Build optional dashboard runtime capabilities from server resources. *)

val run_dashboard_compute :
  ?mode:Server_dashboard_http_runtime_support.dashboard_compute_mode ->
  ?net:Eio_context.eio_net ->
  ?mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config:Coord.config ->
  (config:Coord.config -> sw:Eio.Switch.t -> 'a) ->
  'a
(** Dispatch dashboard compute through the configured runtime support. *)

val state_dashboard_runtime_caps :
  Mcp_server.server_state ->
  Eio_context.eio_net option * Eio.Time.Mono.ty Eio.Resource.t option
(** Extract dashboard runtime capabilities from server state. *)
