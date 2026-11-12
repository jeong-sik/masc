(** The admission of one JSON-RPC message of an MCP endpoint, before any
    method runs.

    It reads the text of the message and nothing else: no server state, no
    credential, no session. The MCP endpoint of the single-user server
    ({!Mcp_server_eio_protocol.handle_request}) and the one of a person on the
    account server ([Server_person_mcp]) admit their messages here, so both
    refuse the same messages with the same answers. *)

type t =
  | Answer of Yojson.Safe.t
      (** What the endpoint answers without running a method. [`Null] is no
          answer: the message is a response, or a notification for a method
          the endpoint does not have. *)
  | Notification of Mcp_transport_protocol.jsonrpc_request
      (** A message without an id, for a method the endpoint has. *)
  | Request of
      { id : Yojson.Safe.t  (** A string or an integer. *)
      ; message : Yojson.Safe.t  (** The JSON that [request] was decoded from. *)
      ; request : Mcp_transport_protocol.jsonrpc_request
      ; protocol : Mcp_transport_protocol.request_protocol
            (** The revision the request itself selects
                ({!Mcp_transport_protocol.classify_request_protocol}). *)
      }

(** The error object of [code] with [message], for the request [id]. *)
val error : ?data:Yojson.Safe.t -> id:Yojson.Safe.t -> Mcp_error_code.t -> string -> Yojson.Safe.t

(** The answer to request metadata that selects no supported revision:
    invalid params, or "unsupported protocol version" with the supported and
    the requested revision as its data. *)
val protocol_error : id:Yojson.Safe.t -> Mcp_transport_protocol.request_protocol_error -> Yojson.Safe.t

(** The checks run in this order, and the first that fails is the answer:
    - text that is not JSON: a parse error;
    - a batch (a JSON array): an invalid request;
    - a response: no answer;
    - a [jsonrpc] other than ["2.0"], or an envelope field that comes twice:
      an invalid request;
    - an envelope that does not decode: an invalid request;
    - a method for which [method_allowed] is false: no answer for a
      notification, and for a request "method not found" naming [endpoint];
    - a notification: {!Notification};
    - an id that is neither a string nor an integer: an invalid request;
    - request metadata that selects no supported revision: invalid params,
      or "unsupported protocol version" with the supported list;
    - on a stateless revision, a method that revision removed
      ([initialize], [notifications/initialized], [ping],
      [resources/subscribe], [resources/unsubscribe], [logging/setLevel]):
      "method not found";
    - on a stateless revision, [tools/call], [resources/read] or
      [prompts/get] with continuation fields: invalid params, because no
      endpoint here issues a resumable request.

    What passes is a {!Request}. *)
val admit : method_allowed:(string -> bool) -> endpoint:string -> string -> t
