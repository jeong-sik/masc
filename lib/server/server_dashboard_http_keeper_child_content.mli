(** Authenticated operator reads of received Child snapshots. Never starts a
    provider, creates a missing journal, or interprets Root settlement as Child
    completeness. Workspace authority is captured from the authenticated server. *)
type route = Receivers of string | Records of string | Hints of string
val route : string -> route option
val permission : Masc_domain.permission
val response : Mcp_server.server_state -> Httpun.Request.t -> route ->
  Httpun.Status.t * Yojson.Safe.t
val handle_get : Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> route -> unit
