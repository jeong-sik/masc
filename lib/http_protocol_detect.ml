(** HTTP protocol detection via connection preface inspection.

    HTTP/2 clients using prior knowledge (h2c) send a 24-byte
    connection preface that starts with [PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n].
    We peek the first bytes of a newly accepted connection (using
    [Unix.recv MSG_PEEK] so the data stays in the kernel buffer) and
    branch to the appropriate handler. *)

type protocol =
  | Http1
  | Http2

(** The first 14 bytes of the HTTP/2 connection preface are enough to
    disambiguate from any valid HTTP/1.x request line, which always
    starts with a method token (GET, POST, ...). *)
let h2_preface_prefix = "PRI * HTTP/2.0"

let h2_preface_len = String.length h2_preface_prefix (* 14 *)

(** [detect_from_fd fd] peeks at the first bytes on [fd] using
    [MSG_PEEK] (non-destructive) and returns the detected protocol.

    Returns [Ok Http2] if the prefix matches the HTTP/2 connection
    preface, [Ok Http1] otherwise.  Returns [Error msg] if the peek
    syscall fails (e.g. connection reset before any data). *)
let detect_from_fd (fd : Unix.file_descr) : (protocol, string) result =
  let buf = Bytes.create h2_preface_len in
  match Unix.recv fd buf 0 h2_preface_len [ Unix.MSG_PEEK ] with
  | n when n >= h2_preface_len ->
    if Bytes.sub_string buf 0 h2_preface_len = h2_preface_prefix
    then Ok Http2
    else Ok Http1
  | n when n > 0 ->
    (* Partial read: not enough bytes for H2 preface, treat as HTTP/1.1.
       This can happen if the client sends a very short request, but any
       valid HTTP/2 client sends the full preface first. *)
    Ok Http1
  | _ ->
    (* 0 bytes = connection closed before sending anything *)
    Error "connection closed before protocol detection"
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
    (* Non-blocking socket with no data yet. Default to HTTP/1.1 —
       any HTTP/2 client sends the connection preface immediately,
       so EAGAIN means a normal HTTP/1.1 request in flight. *)
    Ok Http1
  | exception Unix.Unix_error (err, _fn, _arg) ->
    Error (Printf.sprintf "peek failed: %s" (Unix.error_message err))
;;

(** [detect flow] extracts the underlying Unix FD from an Eio stream
    socket, peeks at the first bytes, and returns the detected protocol.

    The socket data is not consumed; both httpun-eio and h2-eio will
    read it normally afterwards. *)
let detect (flow : _ Eio.Net.stream_socket) : (protocol, string) result =
  match Eio_unix.Resource.fd_opt (flow :> _ Eio.Resource.t) with
  | None -> Error "no Unix FD available on this socket"
  | Some eio_fd ->
    Eio_unix.Fd.use_exn "protocol_detect" eio_fd (fun unix_fd -> detect_from_fd unix_fd)
;;

let protocol_to_string = function
  | Http1 -> "HTTP/1.1"
  | Http2 -> "HTTP/2"
;;
