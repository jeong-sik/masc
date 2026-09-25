(** HTTP/2 frame boundaries observed on one server connection socket.

    The h2 0.13 public API neither names a request's stream nor tells the
    application when the peer resets it. This socket wrapper reads only the
    9-byte frame headers (RFC 9113 §4.1) in both directions; payloads and
    header blocks are passed through untouched and never decoded.

    Inbound reads stop at each preface, frame-header and payload boundary. h2
    parses every read synchronously, so a request callback runs while
    {!request_stream} names the HEADERS or CONTINUATION frame that completed
    its header block. *)

type t

val wrap :
  on_peer_reset:(int -> unit) ->
  on_response_end:(int -> unit) ->
  _ Eio.Net.stream_socket ->
  t
(** [on_peer_reset stream_id] runs when a complete RST_STREAM frame arrives
    from the peer, before h2 reads it. [on_response_end stream_id] runs when
    the server has written a RST_STREAM frame, or a DATA or HEADERS frame
    carrying END_STREAM, for that stream. Writes, shutdown and close are
    forwarded to the wrapped socket. *)

val socket : t -> [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t
(** The socket h2 must read and write through. *)

val request_stream : t -> int option
(** The stream whose header block the last inbound frame completed, or [None]
    when the last complete inbound frame is not HEADERS or CONTINUATION. *)
