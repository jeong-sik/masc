(** Authenticated operator read surface; never starts a provider or repairs storage. *)
type route = Receivers of string | Records of string
val route : string -> route option
val permission : Masc_domain.permission
val response : Mcp_server.server_state -> Httpun.Request.t -> route -> Httpun.Status.t * Yojson.Safe.t
val handle_get : Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> route -> unit
