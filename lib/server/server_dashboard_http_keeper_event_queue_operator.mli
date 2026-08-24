(** Admin-only durable Keeper event-queue control boundary. *)

module Http = Http_server_eio

val operator_permission : Masc_domain.permission

val route : string -> string option

val handle_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  string ->
  unit
