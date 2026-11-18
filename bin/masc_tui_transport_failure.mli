(** Why a TUI request got no HTTP answer, and the one line the TUI says for it.

    The pool's connect failure arrives here as a case, not as text, so the
    line is built once from the case: the origin, what went wrong and when the
    pool tries the origin again. No layer adds its own label in front, and an
    exception's printer output never reaches the screen. The exception goes to
    the TUI log instead. *)

type t =
  | Request_domain_not_started
      (** A request was sent before [Masc_tui_io_domain] started: a
          bootstrap-order bug. *)
  | Client of Masc_http_client.failure

val request_domain_not_started : string
(** The line for {!Request_domain_not_started}. *)

val report : verb:string -> url:string -> t -> string
(** One terminal-safe line for [t]. A connect failure, fresh or held back,
    names its origin and cause and, when the pool holds the origin back, the
    seconds until it tries again; the same cause reads the same either way.
    Any other failure names [verb] and [url]. A fresh connect failure is
    written to the TUI log with its exception. *)
