(** Authenticated HTTP adapter for exact paused-work inventory and disposition. *)

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

val handle_post :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
