(** Workspace-bound, read-only Goal payout observation shared by HTTP/1 and H2. *)

val response :
  config:Workspace.config -> Httpun.Request.t ->
  Httpun.Status.t * Yojson.Safe.t

val generation_headers : (string * string) list
(** The server process and Dashboard execution-publication identities that
    made this response. They are different identities and are not interchangeable. *)
