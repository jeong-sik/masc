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
    callers consume only the [protocol] variant, the two
    detector entry points, and the printable converter. *)

type protocol =
  | Http1
  | Http2

val detect_from_fd :
  Unix.file_descr ->
  (protocol, string) result
(** [detect_from_fd fd] peeks the first bytes of [fd] using
    [MSG_PEEK] and classifies the protocol.

    Returns [Ok Http2] when the peek matches the H2 preface
    prefix, [Ok Http1] for any other observed bytes (including
    a partial read shorter than the preface — any valid H2
    client sends the full preface immediately).

    [Ok Http1] is also returned for [EAGAIN] / [EWOULDBLOCK]
    on a non-blocking socket — an in-flight HTTP/1.1 request
    is the most likely cause.

    Returns [Error msg] for [recv = 0] (peer closed before
    sending) and for any other [Unix.Unix_error]
    (formatted via [Unix.error_message]). *)

val detect :
  _ Eio.Net.stream_socket ->
  (protocol, string) result
(** Eio adapter around {!detect_from_fd}: extracts the underlying
    [Unix.file_descr] via [Eio_unix.Resource.fd_opt] and runs the
    peek under [Eio_unix.Fd.use_exn "protocol_detect"].

    Returns [Error "no Unix FD available on this socket"] when
    the flow has no Unix FD (e.g. an in-memory transport). *)

val protocol_to_string : protocol -> string
(** ["HTTP/1.1"] / ["HTTP/2"] — printable form for log lines and
    metric labels. *)
