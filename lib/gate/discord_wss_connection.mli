(** TLS+WSS handshake helper for Discord Gateway.

    Composes Eio TCP connect, [Tls_eio.client_of_flow], HTTP/1.1 Upgrade,
    and [Websocket.Make(Cohttp_eio.Private.IO)] frame loop into a single
    [connect] call. Stack matches [ushitora-anqou/discordml]'s [Httpx.Ws].

    See RFC-0203 §Why for why the [httpun-ws] family was rejected
    (its client constructor wants an fd-backed socket but [Tls_eio.t] is
    a flow without an fd, so the two don't compose for client-mode WSS
    over TLS).

    A writer fiber is forked on [sw]; tearing down the switch tears down
    the writer. Reads happen synchronously on the caller's fiber.

    System trust store is used for TLS via [Ca_certs.authenticator].
    No authenticator override is exposed by design — we connect to one
    well-known host (Discord). *)

type conn

val connect :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  url:string ->
  conn
(** [connect ~sw ~env ~url] performs the full WSS handshake.

    [url] must be [wss://host[:port]/path[?query]]. Raises on
    DNS / TCP / TLS / HTTP / WS handshake failure with a [Failure]
    carrying a short diagnostic. *)

val read : conn -> Websocket.Frame.t
(** Blocking read of one frame. Raises on close / protocol error. *)

val write : conn -> Websocket.Frame.t -> unit
(** Enqueue a frame onto the writer fiber. Returns immediately. *)

val close : conn -> unit
(** Tear down this connection: cancels the writer fiber, closes the
    TLS flow and the underlying socket. Idempotent — subsequent calls
    are no-ops. After [close], [read] / [write] raise. *)

val writer_loop :
  take:(unit -> Websocket.Frame.t) ->
  write_string:(string -> unit) ->
  unit
(** Writer fiber body: encodes frames obtained from [take] and pushes
    the bytes via [write_string] until either raises.  [Eio.Io] is
    contained — the cause is logged at warn level — because the writer
    runs on the per-session switch and an escaping exception would tear
    down the whole gateway client.  Every other exception (including
    cancellation) propagates.  Exposed for unit tests; [connect] wires
    it to the write queue and the TLS flow. *)
