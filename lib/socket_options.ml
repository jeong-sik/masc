(** Socket options applied to accepted connections.

    Shared by the HTTP/1.1 listener ([lib/server/server_bootstrap_http.ml])
    and the HTTP/2 listener ([lib/http_server_h2.ml]), which previously
    carried byte-identical copies of {!disable_nagle}. *)

let disable_nagle (flow : [> `Platform of [> `Unix ] | `Socket ] Eio.Resource.t) =
  (* TCP_NODELAY on accepted connections: small SSE frames (keeper token
     deltas, dashboard broadcasts) are not held for Nagle coalescing (~up to
     40ms/frame under Nagle + delayed ACK). Set per-connection after accept,
     not on the listen socket, because TCP_NODELAY inheritance from a
     listening socket is Linux-only and is NOT inherited on macOS. Graceful
     degradation: if [setsockopt] fails on an unusual socket the connection
     still works (just with Nagle enabled). *)
  try
    Eio_unix.Fd.use_exn "TCP_NODELAY" (Eio_unix.Net.fd flow) (fun ufd ->
      Unix.setsockopt ufd Unix.TCP_NODELAY true)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()
