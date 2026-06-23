(** TLS+WSS connection for the Discord Gateway, driven by ws-direct.

    masc composes Eio TCP connect + [Tls_eio.client_of_flow] and hands the
    resulting flow to [Ws_direct_eio.Client], which performs the RFC 6455 §4
    opening handshake and drives the frame loop. ws-direct speaks a plain
    [Eio.Flow.two_way], so it composes with a TLS flow (which has no fd)
    directly — removing the impedance that made the [httpun-ws] client
    unusable here (its constructor wants an fd-backed socket; see RFC-0203 §Why
    and RFC-0287).

    The driver fibers live on [sw]; tearing down the switch tears them down.
    Inbound text messages and the peer Close arrive as [inbound] events on an
    internal queue; [read] blocks for the next one.

    System trust store is used for TLS via [Ca_certs.authenticator]. No
    authenticator override is exposed by design — we connect to one well-known
    host (Discord). *)

type conn

(** Application-level inbound event. The endpoint auto-replies to Ping, treats
    Pong observationally, and reassembles fragments, so only complete data
    messages and the peer Close surface. *)
type inbound =
  | Message of string
  | Closed of
      { code : int
      ; reason : string
      }

val connect : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> url:string -> conn
(** [connect ~sw ~env ~url] performs the full WSS handshake.

    [url] must be [wss://host[:port]/path[?query]]. Raises on
    DNS / TCP / TLS / HTTP / WS handshake failure with a [Failure] carrying a
    short diagnostic. *)

val read : conn -> inbound
(** Blocking read of the next inbound event. Raises [End_of_file] on EOF and
    [Failure] on a driver error — matching the gateway reader's existing
    [Wss_closed] mapping (1006 / 1011). *)

val send_text : conn -> string -> unit
(** Send a Text frame. Discord gateway payloads are JSON text. Returns once the
    frame is handed to the writer. *)

val close : conn -> unit
(** Tear down this connection: resolves the session switch's close signal,
    which cancels the driver fibers and closes the TLS flow and the underlying
    socket. Idempotent — subsequent calls are no-ops. After [close], [read]
    raises and [send_text] acts on a closed descriptor. *)

val spawn : conn -> (unit -> unit) -> unit
(** [spawn conn f] forks [f] on [conn]'s session switch, so [f] is cancelled
    when [close conn] tears the connection down. The gateway runs its reader
    loop through this so the reader's lifetime is the connection's: a
    per-connection close cancels the reader (its blocking [read] raises
    [Cancelled]) rather than leaking it on the gateway-wide switch (RFC-0287
    P0). Call before [close]; forking onto an already-closed connection raises. *)

(** Pure bridge helpers, exposed for unit tests. *)
module For_testing : sig
  type nonrec inbound = inbound =
    | Message of string
    | Closed of
        { code : int
        ; reason : string
        }

  type event =
    | Ev_message of string
    | Ev_closed of
        { code : int
        ; reason : string
        }
    | Ev_eof
    | Ev_error of string

  val read_event : event -> inbound
  (** Translate a bridge event to [inbound]; raises [End_of_file] on [Ev_eof]
      and [Failure] on [Ev_error], exactly as [read] does. *)

  val message_to_event : Ws_direct_core.Connection.Message.t -> event option
  (** [Text] -> [Some (Ev_message payload)]; [Binary] -> [None] (Discord with
      compress=false never sends Binary on application frames). *)

  val close_to_event : code:int option -> reason:string -> event
  (** Map an endpoint Close (code optional per RFC 6455 §7.4) to [Ev_closed],
      defaulting a missing code to [close_code_no_status]. *)

  val close_code_no_status : int

  val make_test_conn : sw:Eio.Switch.t -> conn
  (** A connection with a real session switch + [spawn] / [close] but no socket
      (the wsd is a bare, never-driven endpoint; the event stream stays empty).
      For testing the reader-lifetime contract — that [spawn] forks on the
      session switch and [close] cancels it — without a live WS handshake. *)
end
