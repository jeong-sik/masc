(** A TLS session as the stream socket httpun-eio and h2-eio drive.

    [Tls_eio.t] is a two-way flow; the connection handlers of both HTTP
    libraries take an [Eio.Net.stream_socket]. The wrapper forwards reads,
    writes, shutdown and close to the session: [shutdown `Send] sends the TLS
    close_notify, [close] closes the underlying socket. No raw file
    descriptor is exposed. *)

val wrap : Tls_eio.t -> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
