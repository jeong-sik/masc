(** CanAdmin HTTP boundary for absent-owner acknowledgement and explicit retry
    of one blocked dormant task settlement. Authentication is applied by the
    router; [actor] must be the verified bearer credential owner. Task retry
    preparation, finalizer scheduling and completion are separate facts. *)
type target

val route : string -> target option
val permission : Masc_domain.permission

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> target -> unit

val handle_post :
  Mcp_server.server_state -> actor:string -> Httpun.Request.t -> Http_reqd.t ->
  target -> string -> unit
