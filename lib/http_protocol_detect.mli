(** Http_protocol_detect — branch a freshly-accepted TCP socket
    between HTTP/1.1 and HTTP/2 (h2c, prior-knowledge) by peeking
    the connection preface.

    HTTP/2 clients using prior knowledge open with the 24-byte
    preface starting [PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n]. The
    detector reads the first 14 bytes via [Unix.recv MSG_PEEK]
    so the data stays in the kernel buffer and the chosen
    backend (httpun-eio or h2-eio) reads it normally afterwards.

    Internal helpers (the [h2_preface_prefix] string constant
    and the [h2_preface_len] derived integer) are hidden —
    callers consume only the [protocol] variant and the
    detector entry point. *)

type protocol =
  | Http1
  | Http2

val detect :
  _ Eio.Net.stream_socket ->
  (protocol, string) result
(** Eio adapter around {!detect_from_fd}: extracts the underlying
    [Unix.file_descr] via [Eio_unix.Resource.fd_opt] and runs the
    peek under [Eio_unix.Fd.use_exn "protocol_detect"].

    Returns [Error "no Unix FD available on this socket"] when
    the flow has no Unix FD (e.g. an in-memory transport). *)

val detect_from_fd :
  Unix.file_descr -> (protocol, string) result
(** Raw [Unix.file_descr] entry point used by {!detect}; exposed for
    test/test_http_protocol_detect.ml. *)

val protocol_to_string : protocol -> string
(** ["HTTP/1.1"] or ["HTTP/2"]. *)
