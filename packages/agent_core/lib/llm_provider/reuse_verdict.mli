(** Whether a provider connection goes back to the cache after a request
    (RFC-0492 §3.2). Every path that ends a checked-out connection hands
    {!Http_client_cache.release} one of these. *)

type close_reason =
  | Request_failed
  (** The request or the body read ended in an error or an exception, and
      the request may have reached the server. *)
  | Request_not_delivered
  (** The request ended in an error before the server could have received it
      whole: a write call raised an error the transport named as the peer's
      close, and no response byte came back ({!Request_wire.Not_delivered}).
      Counted apart from [Request_failed]; a close has one reason. *)
  | Not_persistent
  (** The request or the response ends the connection: HTTP/1.0 without
      keep-alive, [connection: close] on any line of either side, an
      upgrade, or a body that only the close delimits (RFC 9112 §9.3, §9.6).
      An interim 1xx response is here too: the final response that follows
      it is still unread on the connection. *)
  | Body_not_drained  (** The response body was not read to its end. *)
  | Transport_ended  (** The transport reported end of file. *)

type t =
  | Park
  | Close of close_reason

(** [persistent ~request_headers response] is [true] when neither side ends
    the connection after this exchange and the response body is delimited by
    its own framing. *)
val persistent : request_headers:Http.Header.t -> Http.Response.t -> bool

(** [decide ~request_headers ~response ~body] parks the connection only for a
    persistent exchange whose body was read to its end. A failed read, an
    unread body and a transport end of file close it, in that order. *)
val decide
  :  request_headers:Http.Header.t
  -> response:Http.Response.t
  -> body:[ `Drained | `Not_drained | `Transport_ended | `Failed ]
  -> t
