(** Socket options applied to accepted connections.

    Shared by the HTTP/1.1 listener ([lib/server/server_bootstrap_http.ml])
    and the HTTP/2 listener ([lib/http_server_h2.ml]). *)

val disable_nagle : [> `Platform of [> `Unix ] | `Socket ] Eio.Resource.t -> unit
(** [disable_nagle flow] sets [TCP_NODELAY] on the underlying file
    descriptor of [flow] so small writes are sent without waiting for
    Nagle coalescing.

    Applied per accepted connection rather than on the listening socket,
    because [TCP_NODELAY] inheritance from a listening socket is
    Linux-only and is not inherited on macOS.

    Re-raises {!Eio.Cancel.Cancelled}. Any other exception from
    [setsockopt] is swallowed, leaving the connection with Nagle
    enabled. *)
