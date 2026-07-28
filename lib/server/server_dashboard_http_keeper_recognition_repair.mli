(** Authenticated HTTP adapter for explicit recognition-publication repair. *)

val handle_post :
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  string ->
  unit
