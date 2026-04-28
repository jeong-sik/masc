(** Server_routes_http — top-level HTTP route facade.

    Re-exports the public surface of {!Server_routes_http_common},
    {!Server_routes_http_pages}, {!Server_routes_http_runtime}, and
    {!Server_routes_http_keeper_stream} so callers can [open
    Server_routes_http] and reach all handler helpers unqualified.
    The [include module type of] form auto-tracks the underlying
    modules; when narrower [.mli] files land for those sub-modules,
    this facade automatically picks up the tightened contract.

    {!make_routes} is the canonical builder used by the server entry
    point — it composes every [routes_http_routes_*] sub-router into a
    single Http_server_eio router. *)

include module type of Server_routes_http_common
include module type of Server_routes_http_pages
include module type of Server_routes_http_runtime
include module type of Server_routes_http_keeper_stream

module Http = Http_server_eio

val make_routes :
  port:int ->
  host:string ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Http.Router.t
(** Compose the full route table. Side-effect: registers connectors
    ([Channel_gate_discord_state], [Channel_gate_imessage_state]) on
    [Channel_gate_connector] before wiring routes. *)
