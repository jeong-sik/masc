(** CanAdmin HTTP boundary for observing and explicitly acknowledging a retained
    shutdown record whose owner is absent. Authentication is applied by the
    router; [actor] must be the verified bearer credential owner. *)
type target

val route : string -> target option
val permission : Masc_domain.permission

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> target -> unit

val handle_post :
  Mcp_server.server_state -> actor:string -> Httpun.Request.t -> Httpun.Reqd.t ->
  target -> string -> unit
