(** The request-entry check of {!Request_workspace_precondition} (#43356).

    Both entries, HTTP/1.1 and the HTTP/2 gateway, run it right before
    routing, so a request whose expected workspace is not this server's never
    reaches its handler, and no route keeps a check of its own. *)

val served_workspace : unit -> Request_workspace_precondition.workspace option
(** The workspace this server serves, resolved now from the server state with
    {!Server_base_path_diagnostics.served_paths} -- the pair [/health]
    reports -- or [None] before the server state exists. A request that
    carries no precondition never resolves it. *)

val check_request :
  served:(unit -> Request_workspace_precondition.workspace option) ->
  ready:bool ->
  path:string ->
  Httpun.Request.t ->
  Request_workspace_precondition.decision
(** The decision for [request] at [path]. [served] is called only for a
    well-formed precondition. [/health], the probe a client reads after a
    refusal, is never checked. *)

val check_current_request :
  path:string -> Httpun.Request.t -> Request_workspace_precondition.decision
(** {!check_request} against {!served_workspace} and the startup
    readiness. *)

val refusal_status :
  Request_workspace_precondition.refusal ->
  [> `Bad_request | `Conflict | `Service_unavailable ]
(** 400 for a malformed precondition, 409 for another workspace, 503 while
    booting. *)

val refusal_headers : Request_workspace_precondition.refusal -> (string * string) list
(** [retry-after] while booting, as {!Server_auth.not_initialized_headers}. *)

val refusal_body : Request_workspace_precondition.refusal -> Yojson.Safe.t
(** A {!Server_refusal} body. It names no server path. *)

val guard_http1 :
  path:string -> Httpun.Request.t -> Httpun.Reqd.t -> admitted:(unit -> unit) -> unit
(** The HTTP/1.1 entry: answer a refused request on [reqd], or run
    [admitted]. The HTTP/2 gateway makes the same {!check_current_request}
    match with its own responder and CORS headers. *)
