(** One HTTP/1.1 server-sent-events response (RFC-0493 §3.1).

    A frame is written only by {!send}. [send] returns once httpun has handed
    the frame to the socket, once the connection has closed, or once
    [stalled_after_s] has passed. A client that stops reading therefore holds
    each sending fiber at its frame, and the bytes the server keeps for that
    client are at most one frame per sending fiber. The writer itself is not
    reachable from outside this module, so no caller can write a frame
    without waiting for it. *)

type t

type outcome =
  | Written  (** The frame reached the socket. *)
  | Closed
  (** The response was closed, by this server or by the client, before the
      frame reached the socket. *)
  | Stalled
  (** The frame did not reach the socket within [stalled_after_s]. The
      response is closed before [send] returns. A client that went away while
      the frame was still in the response body ends here too: a failed
      connection closes the body without answering its flush (httpun
      [Reqd.report_error]). *)

val respond :
  clock:_ Eio.Time.clock ->
  stalled_after_s:float ->
  Httpun.Reqd.t ->
  Httpun.Response.t ->
  t
(** [respond ~clock ~stalled_after_s reqd response] starts the streaming
    response. Production routes pass
    {!Server_mcp_transport_http_headers.sse_stalled_after_s}. *)

val send : t -> string -> outcome
(** [send t frame] writes the whole [frame] and waits for it. Several fibers
    may send on one response; each frame is written whole and in the order
    the writes happened. The wait does not hold the lock the writes take, so a
    {!close} never waits on another fiber's frame, and a waiting [send] can be
    cancelled. A frame that reaches the socket just as the time runs out is
    [Written]. *)

val close : t -> unit
(** Ends the response. A later {!send} returns [Closed]. Closing twice is the
    same as closing once. *)

val is_closed : t -> bool
