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
      (** The server's own [annotations.readOnlyHint]. [None] means it did
          not say, which is not the same as saying no: a caller deciding
          whether to run this unasked has to treat silence as "might
          write". masc puts the same field on its own listing, so this is
          the same vocabulary read in the other direction. *)
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
}

type error =
  | Transport of string
  | Unauthorized of { resource_metadata : string option }
      (** The server refused the token. [resource_metadata] is what its
          [WWW-Authenticate] pointed at, which is where an OAuth client goes
          to find out how to get a token this server would accept (RFC
          9728). Kept rather than folded into a status code because that
          pointer is the only part worth acting on. *)
  | Http of { status : int; body : string }
  | Rpc of { code : int; message : string }
      (** The server answered, and said no. *)
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

type t

val connect :
  ?post:post -> url:string -> access_token:string -> unit -> (t, error) result
(** Open a session: [initialize], then the [initialized] notification.

    A session id, if the server minted one, is carried on every later
    request. A server that mints none is not an error -- the stateless
    revisions of the protocol do exactly that. *)

val negotiated_protocol_version : t -> string
(** The version the {e server} named, not the one this offered. A server
    that names one this build does not speak is refused at {!connect}
    rather than being talked to in a dialect neither side agreed on. *)

val session_id : t -> string option

val list_tools : ?post:post -> t -> (tool list, error) result

val call_tool :
  ?post:post ->
  t ->
  name:string ->
  arguments:Yojson.Safe.t ->
  (tool_result, error) result
