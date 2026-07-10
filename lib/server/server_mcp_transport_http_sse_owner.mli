(** Request-server-scoped lifecycle coordination for MCP-adjacent SSE wire ids.

    Durable initialized-session truth comes exclusively from the injected
    {!Server_mcp_transport_session_store.t}. Dashboard Observer, Presence, and
    AG-UI streams may start from a client-generated id, so this module adds
    connection leases without persisting phantom MCP protocol sessions. *)

type t
type lease
type operation_lease
type deletion
type committed_deletion

val create : sessions:Server_mcp_transport_session_store.t -> t
(** Creates an isolated lifecycle context for one HTTP transport-session store.
    No owner, gate, derived-wire, deletion, mutex, or generation state is shared
    with another context. *)

val sessions : t -> Server_mcp_transport_session_store.t
(** Returns the durable session store injected into this context. *)

type delete_start =
  | Prepared_delete of deletion
  | Resume_committed_delete of committed_deletion

type retained_delete_authorization =
  | No_retained_delete
  | Retained_delete_authorized
  | Retained_delete_rejected of { message : string }
  | Retained_delete_in_progress

type lifecycle_error =
  | Session_terminating of { session_id : string }
  | Session_unknown of { session_id : string }
  | Session_owner_rejected of { message : string }

val lifecycle_error_to_string : lifecycle_error -> string

val begin_operation :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  require_known:bool ->
  (operation_lease, lifecycle_error) result
(** Opens one generation-bound unit of session work. DELETE atomically changes
    the gate to draining, after which no new operation can start. When
    [require_known] is true, the known-session and immutable credential-owner
    checks share this same linearization point. *)

val finish_operation : t -> operation_lease -> unit
(** Releases an operation exactly once. The final release resolves a pending
    DELETE drain without polling or an elapsed-time heuristic. *)

val validate_mcp_session_owner_for_request :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val validate_mcp_sse_session_owner_for_request :
  t ->
  session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val claim_mcp_sse_session_owner_for_request :
  t ->
  session_id:string ->
  ?lifecycle_session_id:string ->
  sse_kind:Sse.session_kind ->
  requester:Server_transport_admission.identity ->
  (lease, string) result

(** [lifecycle_session_id] defaults to [session_id]. Presence-style derived
    wire ids pass their initialized transport session here, so validation,
    DELETE draining, and exact dependent cleanup share one lifecycle gate. *)

val activate : t -> lease -> client_id:int -> (unit, string) result
val commit_previous_retirement : t -> lease -> (int option, string) result
(** Irrevocably prevents a failed replacement claim from restoring its prior
    active lease and returns that connection's SSE client id.  [Error] means
    DELETE or a newer owner superseded the claim, so callers must perform no
    session-id-scoped hook or connection mutation.  Successful callers clear
    and stop only the returned client id; this keeps stale reconnect fibers
    from tearing down a newer generation. *)

val release : t -> lease -> unit

val ensure_backing_session_for_owner :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result

val authorize_mcp_session_delete :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (unit, string) result
(** Authorizes a fresh DELETE from durable active-session ownership. Unknown
    and already-deleted ids fail explicitly; committed in-process cleanup
    retries use {!committed_delete_authorization}. *)

val begin_mcp_session_delete :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (deletion, string) result
(** Atomically authorizes the requester and closes the generation gate to new
    POST/SSE setup operations. Existing operations retain exact leases and must
    finish before deletion can be committed. In-memory and on-disk session
    state are not mutated by this prepare phase. *)

val begin_mcp_session_delete_or_resume :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  (delete_start, string) result
(** Starts a fresh deletion or returns the exact committed cleanup plan left by
    an earlier failed cleanup. Resume authorization is checked against the
    immutable owner captured before durable deletion; Admin remains an
    explicit override. *)

val retained_delete_authorization :
  t ->
  session_id:string ->
  requester:Server_transport_admission.identity ->
  retained_delete_authorization
(** Read-only preflight for a durability-pending prepared DELETE or committed
    cleanup retry.  Both use the immutable owner captured before the active
    store record became unavailable. *)

val await_mcp_session_delete_drain : t -> deletion -> unit
(** Waits for the exact generation's admitted operations to finish. There is
    no timeout or polling interval. *)

val retain_mcp_session_delete_for_retry :
  t -> deletion -> (unit, string) result
(** Marks the exact drained generation as available for one authenticated
    persistence retry while keeping its operation gate closed.  Concurrent
    retries cannot both claim it. *)

val commit_mcp_session_delete :
  t -> deletion -> (committed_deletion, string) result
(** After durable transport-session removal, installs the connection tombstone
    and marks the exact drained generation committed.  The returned immutable
    cleanup plan is frozen at that same linearization point. *)

val committed_deletion_active_connections :
  committed_deletion -> (string * int) list
(** Returns the active [(wire_session_id, client_id)] targets frozen by
    {!commit_mcp_session_delete}. *)

val committed_deletion_wire_sessions : committed_deletion -> string list
(** Returns every wire id reserved by the committed lifecycle deletion,
    including disconnected derived Presence/Observer ids. *)

val abort_mcp_session_delete : t -> deletion -> (unit, string) result
(** Reopens a prepared, fully drained generation when durable persistence
    failed before commit. Existing transport state remains authoritative. *)

val finish_mcp_session_delete : t -> committed_deletion -> unit
(** Removes only the matching committed deletion generation after all
    connection, client, backing-session, and resource-subscription cleanup
    succeeded. MCP initialization never accepts a client-supplied unknown id,
    so completed ids cannot be reused by delayed requests. *)
