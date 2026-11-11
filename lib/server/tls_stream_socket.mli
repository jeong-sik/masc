(** A TLS session as the stream socket httpun-eio and h2-eio drive.

    [Tls_eio.t] is a two-way flow; the connection handlers of both HTTP
    libraries take an [Eio.Net.stream_socket]. The wrapper forwards reads,
    writes, shutdown and close to the session: [shutdown `Send] sends the TLS
    close_notify, [close] closes the underlying socket. No raw file
    descriptor is exposed.

    The session's shutdown writes the close_notify and leaves the socket
    under it open both ways (tls-eio [shutdown]), so that socket does not see
    the sending side end. [on_send_shutdown] runs before a [shutdown] that
    ends it, [`Send] or [`All]: the server passes
    {!Server_connection_socket.send_side_closed}, which gives the peer a
    bound to close its side (RFC-0518 D4). *)

val wrap :
  on_send_shutdown:(unit -> unit) ->
  Tls_eio.t ->
  [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
