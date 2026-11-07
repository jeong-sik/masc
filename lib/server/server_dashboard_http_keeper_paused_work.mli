(** Authenticated HTTP adapter for exact paused-work inventory and disposition. *)

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit

val handle_post :
  Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> string -> unit
