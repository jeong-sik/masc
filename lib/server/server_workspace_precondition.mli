(** The request-entry check of {!Request_workspace_precondition} (#43356) plus
    the optional [X-Masc-Expected-Instance] and [X-Masc-Expected-Workspace]
    guard headers.

    Both entries, HTTP/1.1 and the HTTP/2 gateway, run it right before
    routing, so a request whose expected workspace or server instance is not
    this server's never reaches its handler, and no route keeps a check of its
    own. *)

val expected_instance_header : string
(** ["x-masc-expected-instance"]. Optional header matching
    {!Build_identity.runtime_instance_id}. *)

val expected_workspace_header : string
(** ["x-masc-expected-workspace"]. Optional header matching either the served
    canonical [base_path] or its lowercase SHA-256 hex digest. *)

val served_workspace : unit -> Request_workspace_precondition.workspace option
(** The workspace this server serves, resolved now from the server state with
    {!Server_base_path_diagnostics.served_paths} -- the pair the reader's
    [/health] reports -- or [None] before the server state exists. A request that
    carries no precondition never resolves it. *)

val check_request :
  served:(unit -> Request_workspace_precondition.workspace option) ->
  ready:bool ->
  path:string ->
  Httpun.Request.t ->
  Request_workspace_precondition.decision
(** The decision for [request] at [path]. [served] is called only for a
    well-formed precondition. [/health], the probe a client that may read the
    server's state reads after a refusal, is never checked. *)

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

type v2_guard_decision =
  | Guard_pass
  | Guard_refused of
      { status : Httpun.Status.t
      ; headers : (string * string) list
      ; body : Yojson.Safe.t
      }

val check_v2_guard :
  instance_id:string ->
  served:(unit -> Request_workspace_precondition.workspace option) ->
  ready:bool ->
  path:string ->
  Httpun.Request.t ->
  v2_guard_decision
(** Check the optional [X-Masc-Expected-Instance] and
    [X-Masc-Expected-Workspace] headers. Returns {!Guard_pass} when both are
    omitted or on [/health]. Returns [409 Conflict] with
    [{"error":"workspace_mismatch",...}] when either header is supplied and
    mismatched. *)

val guard :
  path:string -> Httpun.Request.t -> Http_reqd.t -> admitted:(unit -> unit) -> unit
(** The ingress entry on either transport: answer a refused request on
    [reqd], or run [admitted]. *)
