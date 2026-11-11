(** The socket of an accepted HTTP connection, with the time bounds a
    connection has as a whole (RFC-0518 D4, D6).

    httpun and h2 give a connection no bound of their own: a peer that stops
    taking bytes holds the connection's writer at its socket write, and a peer
    that never closes holds the reader that waits for its end. The bounds of
    an HTTP/2 stream ({!Http_h2_stream.Stream_end}) end the stream, which
    needs the connection to carry the RST_STREAM. This module ends the
    connection.

    {1 Writes}

    A write goes to the kernel in pieces of at most {!write_piece_bytes}.
    Each piece has {!write_bound_s} to get there whole. A piece that does not
    is logged at warn and the connection is cut. A peer that keeps taking
    pieces is never cut, however long the whole write lasts: the bound is a
    smallest rate, one piece per bound, not a longest response.

    One write is in flight at a time, and a writer keeps its turn until
    every piece of what it gave is with the kernel. A second writer waits for
    that turn, so the bytes of one write reach the socket in one run: tls-eio
    writes a record from its reading path as well as from its writing path,
    and the two do not land inside each other.
    [copy] keeps the turn the same way while it reads its source, and the
    bound is taken only while a piece is on its way to the kernel: a source
    that is slow to read holds the other writers back with no bound. Nothing
    in the server copies into this socket.

    A write that fails because the peer reset or closed the connection ends
    with [End_of_file], which is what gluten takes for a closed connection: it
    then answers every flush that waits. Any other exception goes to the
    connection's error handler and leaves those flushes unanswered.

    {1 After the server closed its sending side}

    gluten shuts down the sending side when the writer is done and then reads
    until the peer closes. A peer that keeps its side open past
    {!write_bound_s} is logged at info and the connection is cut. A TLS
    session's shutdown writes only its close_notify and leaves this socket
    open, so {!Tls_stream_socket} reports it with {!send_side_closed}.

    {1 Preparation}

    {!prepare} gives the step before the first request
    {!preparation_bound_s}: the TLS handshake, the choice between HTTP/1.1
    and HTTP/2, or the wait for the first bytes.

    {1 A cut connection}

    Both directions of the socket are shut down, with [SO_LINGER] zero. A
    write in flight and every later write end with [End_of_file], and a read
    sees the end of the stream, so both of gluten's loops end and the accept
    loop closes the socket. That close resets the connection and frees what
    the peer did not take; without the option the kernel would keep the
    socket until the peer acknowledged every byte.

    The bounds are measured on the clock [wrap] is given. Sleeps are relative
    and do not move with that clock. A write's start is a reading of it: a
    piece in flight while the clock is set back is cut up to one more bound
    late, and one in flight while it is set forward that much early. *)

type t

val write_piece_bytes : int
(** 256 KiB. With {!write_bound_s} that is 2.9 KiB a second, the slowest
    peer that is not cut while more than a piece waits. *)

val write_bound_s : float
(** {!Server_mcp_transport_http_headers.sse_stalled_after_s}: the server
    keeps one stall bound. *)

val preparation_bound_s : float
(** 30 seconds. *)

val wrap :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  listener_tag:string ->
  Eio.Net.Sockaddr.stream ->
  [> [> `Generic | `Unix ] Eio.Net.stream_socket_ty ] Eio.Resource.t ->
  t
(** [wrap ~sw ~clock ~listener_tag client_addr flow] bounds the accepted
    [flow]. The fibers that watch the bounds are daemons of [sw], the
    connection's switch, and end with it. [listener_tag] and [client_addr]
    name the connection in the line a cut logs. The switch that accepted
    [flow] still owns it. *)

val socket : t -> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
(** What the connection's handler reads and writes: httpun-eio, h2-eio,
    tls-eio or protocol detection. Reads, shutdown and close are forwarded to
    the accepted socket. No raw file descriptor is exposed, so no reader or
    writer goes round the bounds. *)

val prepare : t -> (unit -> 'a) -> 'a option
(** [prepare t step] is [Some (step ())] when [step] returns within
    {!preparation_bound_s}. Otherwise [step] is cancelled, the connection is
    cut and the result is [None]; the caller logs it, since only the caller
    knows what the step was. An exception of [step] is the caller's. *)

val send_side_closed : t -> unit
(** The server sends nothing more on this connection, although the socket's
    own sending side stays open: a TLS session ends with a close_notify. The
    peer then has {!write_bound_s} to close, as after a shutdown of the
    sending side. Telling twice is the same as telling once. *)

val await_first_bytes : t -> unit
(** Returns once the peer's first bytes can be read, or its end. Nothing is
    consumed. The step {!prepare} gets on a listener with nothing else to
    prepare. *)
