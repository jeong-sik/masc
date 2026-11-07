(** The response handle of one HTTP request, the same for every transport
    that carries requests into the server (RFC-0512 D1, D2).

    A route handler receives a {!t} and answers through it. The handle knows
    which transport the request came on; the handler does not. HTTP/1.1
    requests come from httpun ({!of_gluten}, {!of_httpun}); HTTP/2 requests
    come from h2 ({!of_h2}).

    Status and header values are httpun's on every transport: a handler
    builds one [Httpun.Response.t] and the handle translates it where the
    wire format differs. On HTTP/2 the handle lowercases header names, drops
    the connection-specific fields of RFC 9113 §8.2.2 and converts the status
    code. *)

type t

(** The protocol-upgrade capability of an httpun-eio connection (RFC-0281,
    RFC-0287). Only an HTTP/1.1 handle from {!of_gluten} carries one: HTTP/2
    has no 101 and no connection to hand over. *)
type upgrade =
  { switch_protocols : Httpun.Headers.t -> (unit -> unit) -> unit
    (** Sends the 101 with these headers and calls the continuation once it is
        written, so the continuation can hand the socket over with {!drive}. *)
  ; drive : Gluten.impl -> unit
    (** Hands the post-101 socket to another protocol runtime. *)
  }

(** Whether the transport writer took a response. [Rejected_by_writer] means
    the request could no longer take one: the client had left and the
    library's own error path had already answered, or on HTTP/2 the
    listener's response capacity was exhausted and an empty 503 went out
    instead. Neither value says the peer received the bytes. It is the sum
    {!Transport_metrics} counts. *)
type acceptance = Transport_metrics.response_write_acceptance =
  | Accepted_by_writer
  | Rejected_by_writer

val of_gluten : Httpun.Reqd.t Gluten.Reqd.t -> t
(** The handle for a request the httpun-eio connection handler delivers. It
    carries the connection's {!upgrade} capability. *)

val of_httpun : Httpun.Reqd.t -> t
(** A handle over a bare httpun descriptor, without an upgrade capability:
    in-memory connections in tests, fixtures. *)

val of_h2
  :  stream_sw:Eio.Switch.t
  -> ledger:Http_h2_response_ledger.request
  -> H2.Reqd.t
  -> t
(** The handle for one HTTP/2 stream. [stream_sw] is the switch that ends
    with the stream; deferred body work runs on it. [ledger] is the request's
    scope in the listener's response ledger: every response byte is reserved
    there before it is written. The request is read as httpun's: the method
    and target are shared types, [:authority] becomes a [host] field when the
    request carries none, and the version is 2.0. *)

val request : t -> Httpun.Request.t

val protocol : t -> Transport_metrics.http_protocol
(** The transport the request came on, for metric and log labels. *)

val upgrade : t -> upgrade option
(** [Some] only for a handle from {!of_gluten}. [Http_server_eio.Router.dispatch]
    answers 426 when a WebSocket route is matched on a handle without it. *)

val try_respond_with_string : t -> Httpun.Response.t -> string -> acceptance
(** Writes the whole response. A write the request can no longer take is
    logged once (debug for the late-response shapes {!Late_response} knows,
    warn with a backtrace for anything else) and reported as
    [Rejected_by_writer]. On HTTP/2 the body is reserved in the ledger first;
    when the capacity is exhausted or the request is already closed, the
    client gets an empty 503 [no-store] that keeps the response's other
    headers, and the result is [Rejected_by_writer]. [Eio.Cancel.Cancelled]
    passes through. *)

val respond_with_string : t -> Httpun.Response.t -> string -> unit
(** {!try_respond_with_string} for a caller that does not record acceptance.
    The log line is the only trace of a rejected write. *)

(** The body of a streaming response. *)
module Body_writer : sig
  type t

  val write_string : t -> string -> unit
  (** On HTTP/2 the bytes are reserved in the ledger first. When that fails,
      the stream is reset with the ledger's exception and the writer closed,
      so the next {!flush} answers [`Closed] and {!is_closed} is true. *)

  val flush : t -> ([ `Written | `Closed ] -> unit) -> unit
  (** [flush t f] calls [f `Written] once every byte written so far reached
      the output channel, or [f `Closed] once that channel closed first. On a
      writer that is already closed it calls [f `Closed] at once. *)

  val close : t -> unit
  (** On HTTP/2 the close waits for the bytes written so far
      ({!Http_h2_stream.close_after_flush}). *)

  val is_closed : t -> bool
end

val respond_with_streaming
  :  ?flush_headers_immediately:bool
  -> t
  -> Httpun.Response.t
  -> Body_writer.t
(** Starts a streaming response. Raises what the transport library raises when
    the request can no longer take a response ([Failure] from either). *)

(** Why a request body was not delivered. *)
type body_read_error =
  | Too_large of int  (** The limit, in bytes, that the body exceeded. *)
  | Internal of exn
      (** [on_body] raised, or the transport handed over a request whose body
          length it had already refused; both libraries answer such a request
          before a handler sees it. *)

val read_body
  :  t
  -> max_bytes:int
  -> on_body:(string -> unit)
  -> on_error:(body_read_error -> unit)
  -> unit
(** Reads the whole request body, at most [max_bytes]. A declared or streamed
    excess stops the read and reports [Too_large]; [on_body] runs once with
    the complete body. On HTTP/2 both callbacks run in a fiber of the stream
    switch after a yield (RFC-0350), and completion is checked again there, so
    a stream reset after EOF delivers nothing. *)

val report_exn : t -> exn -> unit
(** Tells the transport the request failed with [exn]: httpun answers its
    error path, h2 resets the stream. *)

(** The late-response failure shapes of both libraries (#13059). *)
module Late_response : sig
  val classify_write_failure : exn -> string option
  (** [Some msg] for httpun's [Failure "httpun.Reqd.respond_with_string:
      invalid state …"] and [Failure "cannot write to closed writer"], and
      for h2's [Failure "h2.Reqd.respond_with_*: response already …"] and
      [Failure "h2.Reqd.request_body: Stream already closed"]; [None] for
      every other exception, [Eio.Cancel.Cancelled] included, which a caller
      re-raises before classifying. *)
end
