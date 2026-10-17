(** The request-entry check of {!Request_workspace_precondition} (#43356).

    Both entries, HTTP/1.1 and the HTTP/2 gateway, run it right before
    routing, so a request whose expected workspace is not this server's never
    reaches its handler, and no route keeps a check of its own. *)

val publish_served_workspace : base_path:string -> masc_root:string -> unit
(** Record the canonical paths this server serves, once at boot, from the same
    [Server_base_path_diagnostics.detect] whose result [/health] reports. A
    request compares against them without resolving any path. [/health]
    resolves its paths again on each read, so after a symlink in the workspace
    path is retargeted the two differ, and a request that expects the new
    resolution is refused as another workspace until the server restarts. *)

val check_request :
  identity:Request_workspace_precondition.identity option ->
  ready:bool ->
  path:string ->
  Httpun.Request.t ->
  Request_workspace_precondition.decision
(** The decision for [request] at [path]. [/health], the probe a client reads
    after a refusal, is never checked. *)

val check_current_request :
  path:string -> Httpun.Request.t -> Request_workspace_precondition.decision
(** {!check_request} against the published workspace and the startup
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
