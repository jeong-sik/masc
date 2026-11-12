(** What the tracking wrapper saw one request do on its connection
    (RFC-0492 §3.3).

    One value belongs to one request. A reused connection has carried earlier
    requests, and their response bytes are not this request's, so a value is
    created when the request starts and its counts start at the request's
    first write. *)

type t

val create : unit -> t

(** The transport reported end of file on a read of this request. The
    paths that turn an unclassified exception into the peer's close read it. *)
val eof_seen : t -> bool ref

(** A write call began. Response bytes count from the first one. *)
val write_began : t -> unit

(** A write call raised [exn]. Only the first exception is kept. *)
val write_raised : t -> exn -> unit

(** A read returned [count] bytes of response. Bytes read before the first
    write began are not counted. *)
val bytes_read : t -> int -> unit

type delivery =
  | Not_delivered
  (** The request did not reach the server whole: a write call raised an
      error the transport itself named as the peer's close, and no response
      byte came back. *)
  | Possibly_delivered  (** Every other outcome. The server may have the request. *)

(** [delivery ~names_peer_close t] is [Not_delivered] only when the tracker
    saw a write call raise [exn] with [names_peer_close exn], and read no
    response byte after the first write. [names_peer_close] must be true only
    for an error the transport reported by name (an errno such as [ECONNRESET]
    or [EPIPE]), never for a classifier's default for an error it could not
    read, because [Not_delivered] is what later lets a request be sent again. *)
val delivery : names_peer_close:(exn -> bool) -> t -> delivery
