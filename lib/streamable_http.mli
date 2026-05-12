(** Streamable HTTP Transport for MCP

    Implements MCP spec 2025-03-26 Streamable HTTP transport.
    Key features:
    - POST /mcp: JSON-RPC request/response (stateless or session-bound)
    - GET /mcp: Optional SSE stream for server-initiated notifications
    - Session management via mcp-session-id header

    @see <https://modelcontextprotocol.io/specification/2025-03-26/basic/transports>
*)

(** Transport type *)
type transport = Streamable_HTTP

(** Session state *)
type session = {
  id: string;                 (** Unique session ID (UUID) *)
  created_at: float;          (** Unix timestamp *)
  mutable last_seen: float [@atomic];   (** Last activity timestamp; atomic read/write for unlocked concurrent update via [Session.touch]. *)
  transport: transport;       (** Transport type for this session *)
  subscriptions: string list; (** Event types subscribed *)
}

(** Session manager *)
module Session : sig
  (** Create a new session *)
  val create : transport:transport -> session

  (** Find session by ID *)
  val find : string -> session option

  (** Update last_seen timestamp *)
  val touch : session -> unit

  (** Remove session *)
  val remove : string -> unit

  (** List all active sessions *)
  val list_all : unit -> session list

  (** Cleanup expired sessions (older than ttl_seconds) *)
  val cleanup : ttl_seconds:float -> int
end

(** Response modes for /mcp endpoint *)
type response_mode =
  | Json_response of Yojson.Safe.t       (** Single JSON-RPC response *)
  | Json_batch of Yojson.Safe.t list     (** Deprecated compatibility constructor; new requests should not use batch *)
  | Sse_upgrade                          (** Upgrade to SSE stream *)
  | Error_response of int * string       (** HTTP error (status, message) *)

type request_handler =
  Yojson.Safe.t -> Yojson.Safe.t

(** Handle POST /mcp request
    @param session_id Optional session ID from mcp-session-id header
    @param body Request body (JSON-RPC)
    @param request_handler Handler for each JSON-RPC request
    @return (response_mode, session option)

    Batch JSON-RPC payloads are rejected with [Error_response (400, ...)]. *)
val handle_post :
  ?session_id:string ->
  body:string ->
  ?request_handler:request_handler ->
  unit ->
  (response_mode * session option)

(** Handle GET /mcp request (SSE stream setup)
    @param session_id Optional session ID from mcp-session-id header
    @return Either session for streaming or error *)
val handle_get :
  ?session_id:string ->
  unit ->
  (session, string) result

(** Check if request wants Streamable HTTP (vs legacy SSE) *)
val is_streamable_request : Httpun.Request.t -> bool

(** Extract session ID from request headers *)
val get_session_id : Httpun.Request.t -> string option

(** Add session ID to response headers *)
val with_session_header : session -> (string * string) list -> (string * string) list
