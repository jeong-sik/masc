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

val with_connection_switch : Eio.Switch.t -> (unit -> 'a) -> 'a
(** [with_connection_switch sw f] runs [f], the handler of one HTTP/1.1
    connection, with [sw] as that connection's scope. {!of_gluten} called
    inside reads it; httpun itself gives a request no scope. *)

val of_httpun : Httpun.Reqd.t -> t
(** A handle over a bare httpun descriptor, without an upgrade capability:
    in-memory connections in tests, fixtures. *)

val of_h2
  :  stream_end:Http_h2_stream.Stream_end.t
  -> ledger:Http_h2_response_ledger.request
  -> H2.Reqd.t
  -> t
(** The handle for one HTTP/2 stream. [stream_end] is the stream's scope,
    which the stream registry makes: deferred body work runs on its switch,
    its end answers the response flushes still waiting
    ({!Body_writer.flush}), and a flush that waits past its stall bound
    resets the stream. [ledger] is the request's scope in the listener's
    response ledger: every response byte is reserved there before it is
    written. The request is read as httpun's: the method
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
    [Rejected_by_writer]. On HTTP/2 the body is reserved in the ledger first
    and then goes to h2 in 16 KiB slices, two at most at a time
    ({!Http_h2_stream.Response_body}); the call does not wait for it. When
    the capacity is exhausted, the client gets an empty 503 [no-store] that
    keeps the response's other headers, the refusal is logged at warn, and
    the result is [Rejected_by_writer]. An HTTP/2 stream that is already over (see
    {!respond_with_streaming}) gets no response, and the result is
    [Rejected_by_writer]. [Eio.Cancel.Cancelled] passes through. *)

val respond_with_string : t -> Httpun.Response.t -> string -> unit
(** {!try_respond_with_string} for a caller that does not record acceptance.
    The log line is the only trace of a rejected write. *)

val respond_with_shared : t -> Httpun.Response.t -> Shared_body.t -> unit
(** {!respond_with_string} for a body its owner keeps past the request
    (RFC-0518 D5). On HTTP/2 nothing is reserved in the ledger, so the
    response is never refused for capacity and a client that does not read
    it holds none: the bytes go to h2 in the same 16 KiB slices, under the
    stream's flush bound. HTTP/1.1 writes it as it writes a string. *)

(** The body of a streaming response. *)
module Body_writer : sig
  type t

  val write_string : t -> string -> unit
  (** On HTTP/2 the bytes are reserved in the ledger first and wait behind
      those written before them: h2 holds two 16 KiB slices of a body at most
      ({!Http_h2_stream.Response_body}), and the call does not wait for it.
      When the ledger has no room, the refusal is logged at warn, the stream
      is reset ({!Http_h2_stream.reset} with [Out_of_capacity]) and the
      writer closed, so the next {!flush} answers [`Closed] and {!is_closed}
      is true. A closed HTTP/2 writer drops the bytes. *)

  val flush : t -> ([ `Written | `Closed ] -> unit) -> unit
  (** [flush t f] calls [f `Written] once every byte written so far reached
      the output channel, or [f `Closed] once that channel closed first. On a
      writer that is already closed it calls [f `Closed] at once. The h2
      library drains neither a stream the peer reset nor a connection that
      ended while the stream's window was 0, so on HTTP/2 [f `Closed] also
      comes from the end of the stream's switch ({!of_h2}). Each slice of an
      HTTP/2 body has the stall bound to reach the socket. One that waits
      longer resets the stream, and [f] then gets [`Closed]. *)

  val close : t -> unit
  (** Ends the body as complete, and {!is_closed} is true from then on. On
      HTTP/2 the bytes written so far still go out before the stream ends,
      unless the stream ends first (peer reset, stall). A route that raises
      after closing keeps its response ({!response_state} is [Answered]), so
      a route that fails does not close. *)

  val is_closed : t -> bool
  (** True once {!close} was called. On HTTP/2 also true once the stream is
      over: its switch failed or ended, or an error was reported on it. *)

  val stream_end : t -> unit Eio.Promise.t option
  (** On HTTP/2, resolved once the stream's switch ended: the peer reset the
      stream, the stream stalled, or the connection ended ({!of_h2}). A
      producer that waits for events elsewhere races it to stop for a client
      that is gone. [None] on
      HTTP/1.1: httpun reports no end of the connection before the body
      closes, so there a client that went away is noticed by the next write. *)
end

val respond_with_streaming
  :  ?flush_headers_immediately:bool
  -> t
  -> Httpun.Response.t
  -> Body_writer.t
(** Starts a streaming response. [flush_headers_immediately] is httpun's and
    applies to HTTP/1.1: the head is written when the response starts.
    Without it httpun writes the head at the body's first flush or at its
    close. On HTTP/2 the argument is not read and the HEADERS frame always
    goes to the connection at once. Headers that wait for body bytes can
    stay behind when the stream's or the connection's window is zero: no
    byte moves, and they leave only when something else wakes the
    connection's writer.

    An HTTP/2 stream that is already over gets
    a closed writer and h2 is not called: its switch failed or ended, or an
    error was reported on it. That writer drops writes, {!Body_writer.flush}
    answers [`Closed] and {!Body_writer.stream_end} is resolved. Otherwise
    raises what the transport library raises when the request can no longer
    take a response: [Failure] from either, and on HTTP/2 [Assert_failure]
    for a stream h2 already closed while the stream's switch is still open.
    That is a stream h2 reset on its own whose RST_STREAM has not left the
    socket yet (RFC-0518 D1), or one whose response already ended. *)

(** How far a request's response got. *)
type response_state =
  | Not_started  (** No response has started. *)
  | Streaming_open
      (** {!respond_with_streaming} returned a writer that the route has not
          closed and that is still open ({!Body_writer.is_closed} is false). *)
  | Answered
      (** A response started and nothing more will be added to it: a whole
          response, a 101, or a streaming response whose writer the route
          closed or the transport closed. On HTTP/2 the route's close waits
          for the bytes already written, so those still go out. *)

val response_state : t -> response_state
(** Read from the transport and from the writer {!respond_with_streaming}
    returned. A handler that failed is answered by it: a 500 fits only
    [Not_started], and a [Streaming_open] response has to be ended with
    {!report_exn}. *)

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
    a stream reset after EOF delivers nothing.

    A body cut short delivers nothing, and the request has its answer or its
    end by then. On HTTP/1.1 that is a body with fewer bytes than its
    declared length, or a chunked body whose request was reported failed:
    by {!report_exn}, or by httpun itself before a response started. httpun
    leaves no trace of a chunked body it cut after a response started, and
    that body is delivered as it came. *)

(** {1 A handler on another domain}

    RFC http-transport-runs-on-its-own-domain §3.3. httpun and h2 writers are
    not safe across domains, so a handler that runs on another domain than
    its connection gets a handle that touches neither. *)

val relay_scope : t -> Eio.Switch.t option
(** The switch a relayed request's operations are applied under: the stream's
    on HTTP/2, the connection's on HTTP/1.1 ({!with_connection_switch}).
    [None] for a handle without one ({!of_httpun}) and for a handle that is
    itself relayed. *)

val relay : t -> sw:Eio.Switch.t -> post:((unit -> unit) -> unit) -> (t -> unit) -> unit
(** [relay t ~sw ~post handler] hands the request to a handler on another
    domain. [post work] must queue [work] to run on that domain and return.

    [handler] is posted with a handle that sends each thing it asks of the
    request to a fiber forked on [sw], which applies them to [t] in the order
    they were sent. Call this on the connection's domain with [sw] from
    {!relay_scope}. When [sw] is already cancelled no fiber starts on it, so
    nothing is posted: the connection is ending.

    What [handler] raises is reported with {!report_exn}, and what a
    {!read_body} [on_body] raises reaches that read's [on_error] as
    [Internal], as both do on the connection's fiber.

    Through that handle {!try_respond_with_string}, {!respond_with_streaming}
    and {!response_state} wait for the connection's fiber to answer.
    {!Body_writer.write_string}, {!Body_writer.close}, {!read_body} and
    {!report_exn} return at once. The callbacks of {!Body_writer.flush} and
    {!read_body} run on the handler's domain, through [post].
    {!Body_writer.is_closed} trails the transport: it turns true when the
    connection's fiber next looks at the real writer, so a flush answered
    [`Closed] or {!Body_writer.stream_end} is how a producer learns of a
    client that left. {!upgrade} is [None].

    The fiber ends when the response is whole and its flushes are answered,
    or when [sw] ends. A response the transport rejects does not end it: a
    streaming body that was open stays the handler's to close. After that the handle answers as a request that is
    over does: a response is rejected, a streaming response gets a closed
    writer, a flush answers [`Closed], a body read delivers nothing. A flush
    the transport had not answered when [sw] ended is answered [`Closed]
    too: the handler's fiber does not end with the connection, so it is
    never left waiting for one. *)

val report_exn : t -> exn -> unit
(** Tells the transport the request failed with [exn]. Before a response,
    both transports answer with the connection's error handler (500). After
    a streaming response started, HTTP/2 resets the stream
    ({!Http_h2_stream.reset} with [Raised]). HTTP/1.1 stops the body and
    closes the connection after it: a chunked body then lacks its last
    chunk, but a body that ends with the connection (no length, no chunks,
    as masc's HTTP/1.1 SSE) looks to the client like one that finished.
    [exn] is logged once at error: the connection's error handler logs the
    ones it answers (on HTTP/2, {!Http_h2_stream.report_failure}), and the
    body of that answer is a fixed sentence ({!Http_error_body}).

    On HTTP/1.1 httpun also ends the request body, and a {!read_body} still
    waiting for it delivers nothing. *)

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
