(** Select HTTP/1.1 or prior-knowledge HTTP/2 from the initial stream bytes.
    Detection waits cooperatively for a distinguishing byte or a complete H2
    prefix. TCP delivery timing and segmentation do not determine the protocol. *)

type protocol =
  | Http1
  | Http2

val protocol_to_string : protocol -> string

val detect :
  _ Eio.Net.stream_socket ->
  (protocol * [`Generic] Eio.Net.stream_socket_ty Eio.Resource.t, string) result
(** Return the selected protocol and a socket that replays every byte consumed
    during detection before reading directly from the underlying socket.
    Callers must pass the returned socket to the protocol handler.

    At most the H2 distinguishing prefix is buffered. Writes, shutdown and
    close are forwarded to the original socket; its switch retains ownership.
    No raw FD is exposed by the wrapper, so readers cannot bypass the prefix.

    EOF before a protocol can be selected returns [Error]. Cancellation and
    other I/O exceptions propagate. *)
