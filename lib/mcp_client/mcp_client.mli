(** masc talking to somebody else's MCP server.

    The rest of masc answers MCP; this is the one direction that was
    missing. A Keeper's runtime does not have to be an MCP client for this
    to be worth anything -- masc connects, asks what tools are there, and
    offers them on its own surface, so a runtime that speaks no MCP at all
    reaches the same tools.

    It knows JSON-RPC over streamable HTTP and nothing about Keepers, OAuth,
    or where a token came from. A bearer string is handed in.

    Streamable HTTP means one POST can be answered two ways: a JSON body, or
    an event stream carrying the same message. Both are read here, because
    which one arrives is the server's choice and not something a caller
    should have to know. *)

type tool = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  read_only : bool option;
      (** The server's own [annotations.readOnlyHint]. This is descriptive
          metadata, not independent authority for an external call or retry. *)
}

type tool_result = {
  is_error : bool;
      (** The server's own [isError], which is a tool that failed rather than
          a call that did not happen. A caller has to keep those apart: the
          first is an answer to show a model, the second is not. *)
  text : string;
      (** The content blocks joined. A block that is not text is named by its
          type rather than dropped, so a model is not shown a shorter answer
          than the one that arrived. *)
  content : Yojson.Safe.t;  (** the blocks as they came, nothing removed *)
  structured_content : Yojson.Safe.t option;
      (** The server's [structuredContent], if supplied. Its JSON value can
          have any shape; it is not necessarily an object. *)
}

val model_text : tool_result -> string
(** Content for a model, including structured output when present. [text]
    itself remains the original text blocks for machine consumers. *)

type error =
  | Transport of string
  | Unauthorized of { resource_metadata : string option }
      (** The server reported that it refused the token. [resource_metadata] is what its
          [WWW-Authenticate] pointed at, which is where an OAuth client goes
          to find out how to get a token this server would accept (RFC
          9728). Kept rather than folded into a status code because that
          pointer is the only part worth acting on. *)
  | Http of
      { status : int
      ; body : string
      ; www_authenticate : string list
      ; bearer_error : string option
      ; required_scope : string option
      ; resource_metadata : string option
      }
      (** A non-401 HTTP failure. A 403 can carry an insufficient-scope
          challenge; retain it without treating it as a refreshable token. *)
  | Rpc of
      { code : int
      ; message : string
      ; data : Yojson.Safe.t option
      ; http_status : int option
      }
      (** The server answered, and said no. *)
  | Input_required of
      { input_requests : Yojson.Safe.t option
      ; request_state : string option
      }
      (** The operation has not completed. The opaque request state and
          server input requests are retained; this client does not replay the
          operation or claim that it succeeded. *)
  | Before_tool_call of error
      (** Catalog discovery or header preparation failed before the tool
          request was sent. The inner error preserves the actual cause. *)
  | Malformed of string

val error_to_string : error -> string

(** How a request reaches the server. Injected so the wire contract can be
    exercised against recorded answers: a test that needs network is a test
    that does not run. *)
type post =
  url:string ->
  headers:(string * string) list ->
  body:string ->
  (Masc_http_client.response, string) result

val http_post
  :  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t
  -> deadline_s:float
  -> post
(** The production transport for a caller that has a clock: each request of
    a session runs under [deadline_s] on [clock], one window per request. It
    cannot be built without a clock and a deadline: a tools/call is work a
    keeper turn is waiting on with the attempt watchdog off, so a server
    that accepts the connection and never answers is ended by this deadline
    or not at all. A caller with no clock (the web search tool, which runs
    curl as its other providers do) supplies a {!post} of its own, under the
    same rule: it must bound each request. *)

type t

type catalog_binding =
  { input_schema : Yojson.Safe.t
  ; read_only : bool option
  }

type catalog_authority =
  | Unbound
  | Bound of catalog_binding option
      (** The schema and read-only hint bound to the caller's offer or
          approval. [None] means an older approval did not record them;
          bound calls then fail before sending in either protocol era. *)

val connect :
  post:post -> url:string -> access_token:string -> unit -> (t, error) result
(** Probe the stateless protocol with [server/discover], falling back to the
    older [initialize] handshake when the peer does not recognize the probe.
    A legacy session id, if the server minted one, is carried on later
    requests. Modern requests carry their version and client capabilities in
    each request instead. *)

val negotiated_protocol_version : t -> string
(** The version the {e server} named, not the one this offered. A server
    that names one this build does not speak is refused at {!connect}
    rather than being talked to in a dialect neither side agreed on. *)

val session_id : t -> string option

val max_tools_list_pages : int
(** Pages {!list_tools} reads before it refuses a listing that does not end.
    A stopgap for one deadline shared by the whole listing (#46538). *)

val list_tools : post:post -> t -> (tool list, error) result
(** Read every page, treating cursors as opaque, including empty strings. A
    listing that still returns a cursor after {!max_tools_list_pages} pages is
    refused with [Malformed]. *)

val call_tool :
  post:post ->
  ?catalog_authority:catalog_authority ->
  t ->
  name:string ->
  arguments:Yojson.Safe.t ->
  (tool_result, error) result

type state_only_continuation
(** In-memory, single-use continuation of one modern tools/call. It binds
    the original client, tool, arguments and catalog authority; server state
    is opaque and is not exposed to the caller. *)

type state_only_step =
  | Tool_completed of tool_result
  | Tool_continuation of state_only_continuation

type continuation_error =
  | Continuation_consumed
  | Continuation_failed of error

val start_tool_with_continuation :
  post:post ->
  ?catalog_authority:catalog_authority ->
  t ->
  name:string ->
  arguments:Yojson.Safe.t ->
  (state_only_step, error) result
(** Execute once and retain a modern [input_required] response containing
    only [requestState]. Server input requests are not handled by this API
    and remain an {!Input_required} error. The actual offered schema and hint
    are captured even for an unbound initial call. The continuation is not
    durable. *)

val resume_tool_with_state :
  post:post -> state_only_continuation -> (state_only_step, continuation_error) result
(** Retry exactly the bound request with the server's opaque state and a new
    JSON-RPC ID. Refresh and compare the live tool catalog before sending.
    Validation happens before a single caller claims the
    continuation; once claimed for transmission it cannot be reused, even
    if the response is lost. A failed continuation does not prove the
    original operation had no effect. *)
