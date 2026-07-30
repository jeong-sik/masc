(** Admin-only durable Keeper event-queue control boundary. *)

module Http = Http_server_eio

val operator_permission : Masc_domain.permission

val route : string -> string option
val pending_get_route : string -> string option

module For_testing : sig
  val pending_page :
    after:int ->
    limit:int ->
    Keeper_event_queue_state.pending_selection list ->
    Yojson.Safe.t list

  val pending_selection_at :
    queue_index:int ->
    Keeper_event_queue_state.pending_selection list ->
    Keeper_event_queue_state.pending_selection option
end

val handle_get :
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  unit

val handle_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  string ->
  unit
