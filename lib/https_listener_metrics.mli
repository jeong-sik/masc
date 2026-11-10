(** The HTTPS listener's state for [/health], the dashboard transport health
    surface and the OTel scrape (RFC-0512 D6).

    The cleartext listener's state is {!Transport_metrics}; the HTTPS listener
    keeps its own so neither overwrites the other's mode, status or counts. *)

(** Where the served certificate came from. *)
type certificate_source =
  | Configured  (** the files the configuration names *)
  | Self_signed  (** the pair under [<base-path>/.masc/tls/] *)

val certificate_source_to_string : certificate_source -> string
(** ["configured"] or ["self_signed"]. *)

type certificate =
  { source : certificate_source
  ; not_after : Ptime.t  (** the leaf certificate's expiry *)
  }

type status =
  | Off  (** [MASC_HTTPS_PORT] is 0, or the boot has not configured the listener *)
  | Not_started  (** configured, socket not yet bound *)
  | Bind_failed  (** the port could not be bound; HTTPS stays off until the next boot *)
  | Listening
  | Stopped
  | Accept_error  (** the last accept failed; the loop retries with backoff *)

val status_to_string : status -> string

(** What the ALPN extension settled on. [Alpn_none] is a client that sent no
    ALPN; it is served as HTTP/1.1. *)
type negotiated =
  | Alpn_h2
  | Alpn_http1
  | Alpn_none

val configure : port:int -> certificate:certificate -> unit
(** Boot: the listener exists on [port] with [certificate]. The status becomes
    [Not_started]. *)

val subscribe_source_changed : (unit -> unit) -> (unit -> unit)
(** Metadata after listener/connection/TLS lifecycle state changes, outside
    the mutation's result. Callbacks must not block or yield; failures cannot
    replace the source result. Idempotent removal. Reading JSON does not notify. *)

val record_bind_failure : error:string -> unit
val record_started : unit -> unit
val record_stopped : unit -> unit

val record_accept : unit -> unit
(** One accepted TCP connection: the active gauge rises, the status is
    [Listening] and the last error is cleared. *)

val record_connection_closed : unit -> unit
val record_negotiated : negotiated -> unit

val record_handshake_failure : unit -> unit
(** A connection that ended before an application protocol was chosen:
    a TLS alert, a protocol failure, or a peer that left mid-handshake. *)

val record_accept_error : error:string -> unit
val status : unit -> status

val json : ?now:float -> unit -> Yojson.Safe.t
(** The [https_listener] object of [/health] and the dashboard transport
    health payload. [now] (unix seconds) only affects [last_accept_age_seconds]. *)
