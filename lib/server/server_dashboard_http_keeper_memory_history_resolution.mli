(** Admin-only observation and durable submission for one retained history
    original. The router supplies the verified bearer [actor]. GET performs
    only Work.read and the read-only resolution preview. POST persists intent
    before separately requesting the existing detached Memory lane; neither
    handler calls the serialized fence or runs Memory work directly. *)
type target

val route : string -> target option
val permission : Masc_domain.permission

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> target -> unit

val handle_post :
  Mcp_server.server_state -> actor:string -> Httpun.Request.t -> Http_reqd.t ->
  target -> string -> unit
