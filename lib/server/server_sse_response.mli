(** One server-sent-events response (RFC-0493 §3.1) on a {!Http_reqd.t}.

    A frame is written only by {!send}. [send] returns once the transport has
    handed the frame to the socket, once the response has closed, or once
    [stalled_after_s] has passed. A client that stops reading therefore holds
    each sending fiber at its send, and the bytes the server keeps for that
    client are at most one send per sending fiber. A pump's send carries the
    frames it batched (RFC-0493 §7 5b). The writer itself is not
    reachable from outside this module, so no caller can write a frame
    without waiting for it.

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
      (an HTTP/2 peer reset or connection end). *)
  | Stalled
  (** The frame did not reach the socket within [stalled_after_s]. A client
      that went away while the frame was waiting ends here too: httpun closes
      the body of a failed connection without answering its flush (httpun
      reqd.ml [report_error], gluten-eio [writev]). *)

val respond :
  clock:_ Eio.Time.clock ->
  stalled_after_s:float ->
  ?flush_headers_immediately:bool ->
  Http_reqd.t ->
  Httpun.Response.t ->
  t
(** [respond ~clock ~stalled_after_s reqd response] starts the streaming
    response. Production routes pass
    {!Server_mcp_transport_http_headers.sse_stalled_after_s}.
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
    raises, [t] stays open and the exception goes on. *)

val is_closed : t -> bool

val await_closed : t -> unit
(** Returns once the response is closed: by {!close}, by a [send] that did
    not end [Written], or by the transport ending the stream under it (an
    HTTP/2 peer reset or connection end, {!Http_reqd.Body_writer.stream_end}).
    httpun reports no such end, so on HTTP/1.1 only the first two apply. A
    fiber that waits for events elsewhere races this to stop producing for a
    client that is gone. *)
