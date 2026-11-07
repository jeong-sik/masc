(** The response handle of one HTTP request, the same for every transport
    that carries requests into the server (RFC-0512 D1, D2).

    A route handler receives a {!t} and answers through it. The handle knows
    which transport the request came on; the handler does not. This layer
    carries HTTP/1.1 requests from httpun. HTTP/2 joins in RFC-0512 S3.

    Status and header values are httpun's on every transport: a handler
    builds one [Httpun.Response.t] and the handle translates it where the
    wire format differs. *)

type t

(** The protocol-upgrade capability of an httpun-eio connection: hands the
    post-101 socket to another protocol runtime (RFC-0281, RFC-0287). *)
type upgrade = Gluten.impl -> unit

(** Whether the transport writer took a response. [Rejected_by_writer] means
    the request could no longer take one: the client had left and the
    library's own error path had already answered. Neither value says the
    peer received the bytes. It is the sum {!Transport_metrics} counts. *)
type acceptance = Transport_metrics.response_write_acceptance =
  | Accepted_by_writer
  | Rejected_by_writer

val of_gluten : Httpun.Reqd.t Gluten.Reqd.t -> t
(** The handle for a request the httpun-eio connection handler delivers. It
    carries the connection's {!upgrade} capability. *)

val of_httpun : Httpun.Reqd.t -> t
(** A handle over a bare httpun descriptor, without an upgrade capability:
    in-memory connections in tests, fixtures. *)

val request : t -> Httpun.Request.t

val upgrade : t -> upgrade option
(** [Some] only for a handle from {!of_gluten}. [Http_server_eio.Router.dispatch]
    answers 426 when a WebSocket route is matched on a handle without it. *)

val try_respond_with_string : t -> Httpun.Response.t -> string -> acceptance
(** Writes the whole response. A write the request can no longer take is
    logged once (debug for the two late-response shapes {!Late_response}
    knows, warn with a backtrace for anything else) and reported as
    [Rejected_by_writer]. [Eio.Cancel.Cancelled] passes through. *)

val respond_with_string : t -> Httpun.Response.t -> string -> unit
(** {!try_respond_with_string} for a caller that does not record acceptance.
    The log line is the only trace of a rejected write. *)

(** The body of a streaming response. *)
module Body_writer : sig
  type t

  val write_string : t -> string -> unit

  val flush : t -> ([ `Written | `Closed ] -> unit) -> unit
  (** [flush t f] calls [f `Written] once every byte written so far reached
      the output channel, or [f `Closed] once that channel closed first. *)

  val close : t -> unit
  val is_closed : t -> bool
end

val respond_with_streaming
  :  ?flush_headers_immediately:bool
  -> t
  -> Httpun.Response.t
  -> Body_writer.t
(** Starts a streaming response. Raises what the transport library raises when
    the request can no longer take a response ([Failure] from httpun). *)

(** The body of a request, read in pieces. *)
module Body_reader : sig
  type t

  val schedule_read
    :  t
    -> on_eof:(unit -> unit)
    -> on_read:(Bigstringaf.t -> off:int -> len:int -> unit)
    -> unit
  (** One of the two callbacks fires once; the caller schedules the next read
      from inside [on_read]. *)

  val close : t -> unit
end

val request_body : t -> Body_reader.t

val respond_with_upgrade : t -> Httpun.Headers.t -> (unit -> unit) -> unit
(** Sends the 101 and calls the continuation once it is written, so the
    continuation can hand the socket over through {!upgrade}. *)

(** The two late-response failure shapes (#13059). *)
module Late_response : sig
  val classify_write_failure : exn -> string option
  (** [Some msg] for [Failure "httpun.Reqd.respond_with_string: invalid state
      …"] and for [Failure "cannot write to closed writer"]; [None] for every
      other exception, [Eio.Cancel.Cancelled] included, which a caller
      re-raises before classifying. *)
end
