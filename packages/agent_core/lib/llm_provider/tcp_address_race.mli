(** Race resolved TCP addresses before any TLS handshake or HTTP dispatch.
    Each attempt owns its socket scope. Failed/cancelled attempts are closed
    before returning; the winner lives until explicit close, or until [sw] is
    cancelled or finishes. A read or write on the winner observes the caller's
    cancellation before it touches the socket, so when [sw]'s cancellation
    closes the winner, a caller inside [sw] sees [Eio.Cancel.Cancelled],
    never a closed descriptor.
    No timers or address-family preference are added. This is simultaneous
    TCP address racing, not an implementation of RFC 8305. *)
val connect
  :  sw:Eio.Switch.t
  -> net:[> [ `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> Eio.Net.Sockaddr.stream list
  -> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
