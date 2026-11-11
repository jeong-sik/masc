(** One server-sent-events response (RFC-0493 §3.1) on a {!Http_reqd.t}.

    A frame is written only by {!send}. [send] returns once the transport has
    handed the frame to the socket, once the response has closed, or once the
    frame has waited too long. On HTTP/1.1 [send] gives the frame
    [stalled_after_s] itself. On HTTP/2 the stream's flush bound does it
    ({!Http_h2_stream.Stream_end}): it resets a stream whose oldest flush
    waited that long, counting each 16 KiB slice of a long frame on its own,
    and the reset closes the response. A client that stops reading therefore
    holds each sending fiber at its send, and the bytes the server keeps for
    that client are at most one send per sending fiber. A pump's send carries
    the frames it batched (RFC-0493 §7 5b). The writer itself is not reachable
    from outside this module, so no caller can write a frame without waiting
    for it.

    A response belongs to the domain that runs its connection. httpun's
    writer is not domain-safe, and the connection's write loop uses it
    without any lock of ours. *)

type t

type outcome =
  | Written  (** The frame reached the socket. *)
  | Closed
  (** The response was closed before the frame reached the socket: by
      {!close}, by an earlier [send] that did not end [Written], by httpun
      when the connection failed, or by the transport ending the stream
      (an HTTP/2 peer reset, a stalled flush, or connection end). A client
      that went away while the frame was waiting ends here: the connection's
      write ends as a closed connection ({!Server_connection_socket}) and the
      flush is answered. *)
  | Stalled
  (** HTTP/1.1 only: the frame did not reach the socket within
      [stalled_after_s]. A frame waiting when the connection's write fails
      for another reason than the peer's reset ends here too: httpun closes
      the body of a failed connection without answering its flush (httpun
      reqd.ml [report_error], gluten-eio [writev]). An HTTP/2 frame that
      stalls is logged by the stream's flush bound, which resets the stream:
      a [send] on one of that stream's fibers, or in a producer that {!serve}
      runs, is cancelled with it, and a [send] from any other fiber ends
      [Closed]. *)

val respond :
  clock:_ Eio.Time.clock ->
  stalled_after_s:float ->
  ?flush_headers_immediately:bool ->
  Http_reqd.t ->
  Httpun.Response.t ->
  t
(** [respond ~clock ~stalled_after_s reqd response] starts the streaming
    response. [stalled_after_s] by [clock] bounds an HTTP/1.1 frame; an
    HTTP/2 response takes its stream's bound instead. Production routes pass
    {!Server_mcp_transport_http_headers.sse_stalled_after_s}, the bound the
    HTTP/2 listeners give their streams.
    [flush_headers_immediately] is httpun's: the head is written before the
    first frame, for a stream whose first frame can wait. *)

val send : t -> string -> outcome
(** [send t frame] writes the whole [frame] and waits for it. Several fibers
    may send on one response; each frame is written whole and in the order
    the writes happened. A frame that reaches the socket just as the time runs
    out is [Written]. Unless the outcome is [Written], the response is closed
    when [send] returns, and a [Stalled] frame is logged with the request
    path.

    A waiting [send] can be cancelled. Its frame stays in the response and is
    still written if the client reads on. *)

val close : t -> unit
(** Ends the response as complete. A [send] waiting at that moment returns
    [Closed] unless its frame reached the socket first, and every later
    [send] returns [Closed]. Closing twice is the same as closing once.

    A route that fails does not close: the exception then reaches the
    request's error handling with the response still open, and that cuts it
    (an HTTP/2 stream gets RST_STREAM, {!Server_http_ingress.serve}). A
    response the route closed first stays whole, and the exception is only
    logged. {!close_after} closes only when the route ends normally. *)

val close_after : t -> (unit -> 'a) -> 'a
(** [close_after t f] runs [f] and {!close}s [t] when [f] returns. When [f]
    raises, [t] stays open and the exception goes on. Cancellation is such an
    exception too: a cancelled [f] also leaves [t] open. *)

val is_closed : t -> bool

val await_closed : t -> unit
(** Returns once the response is closed: by {!close}, by a [send] that did
    not end [Written], or by the transport ending the stream under it (an
    HTTP/2 peer reset, a stalled flush or connection end,
    {!Http_reqd.Body_writer.stream_end}).
    httpun reports no such end, so on HTTP/1.1 only the first two apply. A
    fiber that waits for events elsewhere races this to stop producing for a
    client that is gone; {!serve} does so for the producer it runs. *)

val serve : sw:Eio.Switch.t -> ?release:(unit -> unit) -> t -> (unit -> unit) -> unit
(** [serve ~sw t produce] runs [produce] in a fiber of [sw] and returns once
    that fiber waits. From then on the response owns its producer (RFC-0518
    D7):

    - [produce] is cancelled once the response is closed ({!await_closed}).
      On HTTP/2 that is when the peer resets the stream, the stream stalls or
      the connection ends, so a producer that waits for its next event does
      not outlive its client. HTTP/1.1 reports no such end: there the
      producer meets the closed response at its next {!send}.
    - When [produce] returns, the response is closed as complete.
    - When [produce] raises, the response is not closed but cut, as the
      response of a request handler that failed is ({!Http_reqd.report_exn}:
      the HTTP/2 stream is reset, the HTTP/1.1 body stops and its connection
      closes), and the exception is logged there. [sw] does not fail. A
      producer that raises after its response ended is logged the same way;
      nothing is left to cut.
    - When [sw] is cancelled while [produce] runs, [produce] is cancelled
      and the response is closed as complete. {!close_after} leaves a
      cancelled response open; a served one is closed, since nothing else
      would end it.
    - [release] runs after the producer ended and the response closed.
      When [sw] was already ending, [produce] does not run; the response is
      closed and [release] runs all the same. What closing or [release]
      raises is logged at warn and the other step still runs.

    [sw] is a switch of the domain that calls [serve] and lives as long as
    the server: the router's switch or the server state's. [Eio.Fiber.fork]
    refuses a switch of another domain, and then nothing is closed or
    released. The producer runs under a switch of its own inside its fiber,
    so a response that ended leaves nothing on [sw]. *)
